import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:grpc/grpc.dart';

import '../gen/agent.pbgrpc.dart';
import 'package:protobuf/well_known_types/google/protobuf/empty.pb.dart';

export '../gen/agent.pbgrpc.dart';

/// A single chat message rendered by the UI.
class ChatMessage {
  ChatMessage(this.role, this.text,
      {this.streaming = false, this.isError = false});
  final String role; // "user" | "assistant"
  String text;
  bool streaming;
  bool isError;
}

/// Owns the gRPC connection to myosd and all shell-visible state.
class AgentIpc extends ChangeNotifier {
  AgentIpc() {
    _connect();
  }

  static String socketPath() =>
      Platform.environment['MYOS_AGENT_SOCKET'] ?? '/run/myos/agent.sock';

  late ClientChannel _channel;
  late AgentClient _stub;
  StreamController<ClientEvent>? _outgoing;
  StreamSubscription<ServerEvent>? _incoming;

  final List<ChatMessage> messages = [];
  bool busy = false;
  bool daemonUp = false;
  DeviceProfile? profile;
  ProviderList? providers;
  ModelList? models;
  LoopList? loops;
  ProjectList? projects;
  RuntimeStatus? runtimeStatus;
  ProviderCommandList? providerCommands;
  ConfirmRequest? pendingConfirmation;
  bool promptOptimizer = true;

  String currentConversationId = 'default';

  String get agentName =>
      profile?.agentName.isNotEmpty == true ? profile!.agentName : 'MyOS';

  Provider? get selectedProvider {
    final p = providers;
    if (p == null || p.selectedProviderId.isEmpty) return null;
    for (final prov in p.providers) {
      if (prov.id == p.selectedProviderId) return prov;
    }
    return null;
  }

  void _connect() {
    _channel = ClientChannel(
      InternetAddress(socketPath(), type: InternetAddressType.unix),
      port: 0,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    _stub = AgentClient(_channel);
    _openChatStream();
    refresh();
  }

  void _openChatStream() {
    _outgoing?.close();
    _incoming?.cancel();
    final outgoing = StreamController<ClientEvent>();
    _outgoing = outgoing;
    _incoming = _stub.chat(outgoing.stream).listen(
      _onServerEvent,
      onError: (Object e) {
        daemonUp = false;
        busy = false;
        notifyListeners();
        _scheduleReconnect();
      },
      onDone: _scheduleReconnect,
    );
  }

  Timer? _reconnect;
  bool _disposed = false;
  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnect ??= Timer(const Duration(seconds: 2), () {
      _reconnect = null;
      _openChatStream();
      refresh();
    });
  }

  Future<void> refresh() async {
    try {
      profile = await _stub.getDeviceProfile(Empty());
      providers = await _stub.listProviders(Empty());
      daemonUp = true;
      final selected = providers!.selectedProviderId;
      models = selected.isEmpty
          ? null
          : await _stub.listModels(ProviderId(id: selected));
      runtimeStatus = await _stub.getRuntimeStatus(
        ChatSessionId(id: currentConversationId),
      );
      providerCommands = selected.isEmpty
          ? null
          : await _stub.listProviderCommands(ProviderId(id: selected));
      loops = await _stub.listLoops(Empty());
      projects = await _stub.listProjects(Empty());
    } on Object {
      daemonUp = false;
    }
    notifyListeners();
  }

  Future<void> refreshLoops() async {
    try {
      loops = await _stub.listLoops(Empty());
      projects = await _stub.listProjects(Empty());
      daemonUp = true;
    } on Object {
      daemonUp = false;
    }
    notifyListeners();
  }

  Future<Loop> createLoop({
    required String name,
    required String goal,
    required int intervalMinutes,
    String projectName = '',
  }) async {
    final created = await _stub.createLoop(LoopSpec(
      name: name,
      goal: goal,
      intervalMinutes: intervalMinutes,
      projectName: projectName,
      level: LoopLevel.LOOP_LEVEL_REPORT,
    ));
    await refreshLoops();
    return created;
  }

  Future<void> setLoopEnabled(String id, bool enabled) async {
    await _stub.setLoopEnabled(SetLoopEnabledRequest(id: id, enabled: enabled));
    await refreshLoops();
  }

  Future<LoopRun> runLoopNow(String id) async {
    final run = await _stub.runLoopNow(LoopId(id: id));
    await refreshLoops();
    return run;
  }

  Future<void> deleteLoop(String id) async {
    await _stub.deleteLoop(LoopId(id: id));
    await refreshLoops();
  }

  Future<LoopRunList> loopRuns(String id) => _stub.getLoopRuns(LoopId(id: id));

  void _onServerEvent(ServerEvent ev) {
    daemonUp = true;
    switch (ev.whichEvent()) {
      case ServerEvent_Event.textDelta:
        if (messages.isEmpty || !messages.last.streaming) {
          messages.add(ChatMessage('assistant', '', streaming: true));
        }
        messages.last.text += ev.textDelta.text;
        break;
      case ServerEvent_Event.error:
        messages.add(ChatMessage('assistant', ev.error.message,
            streaming: false, isError: true));
        break;
      case ServerEvent_Event.turnDone:
        if (messages.isNotEmpty) messages.last.streaming = false;
        busy = false;
        unawaited(refresh());
        break;
      case ServerEvent_Event.confirm:
        pendingConfirmation = ev.confirm;
        break;
      default:
        break;
    }
    notifyListeners();
  }

  void send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || busy || _outgoing == null) return;

    if (trimmed == '/new') {
      clearChat();
      return;
    }

    if (trimmed == '/optimize') {
      promptOptimizer = !promptOptimizer;
      messages.add(ChatMessage('assistant',
          'Prompt optimizer ${promptOptimizer ? 'enabled' : 'disabled'} for this session.'));
      notifyListeners();
      return;
    }

    if (trimmed == '/history') {
      messages.add(ChatMessage('user', trimmed));
      busy = true;
      notifyListeners();
      try {
        final hist = await _stub.getChatHistory(Empty());
        final sb = StringBuffer('**Chat History:**\n\n');
        if (hist.sessions.isEmpty) {
          sb.writeln('No past conversations found.');
        } else {
          for (var i = 0; i < hist.sessions.length; i++) {
            final s = hist.sessions[i];
            sb.writeln('`[${s.id}]` - ${s.preview.replaceAll('\n', ' ')}');
          }
          sb.writeln('\nUse `/load <id>` to resume a conversation.');
        }
        messages.add(ChatMessage('assistant', sb.toString()));
      } catch (e) {
        messages.add(ChatMessage('assistant', 'Failed to fetch history: $e',
            isError: true));
      }
      busy = false;
      notifyListeners();
      return;
    }

    if (trimmed.startsWith('/load ')) {
      final targetId = trimmed.substring(6).trim();
      currentConversationId = targetId;
      messages.clear();
      messages.add(ChatMessage('assistant',
          'Switched to conversation `$targetId`.\n\nThe AI now remembers this context, but past messages are hidden from the UI to save screen space.'));
      _openChatStream();
      notifyListeners();
      return;
    }

    messages.add(ChatMessage('user', trimmed));
    busy = true;
    notifyListeners();
    _outgoing!.add(ClientEvent(
      message: UserMessage(
        conversationId: currentConversationId,
        text: trimmed,
        source: MessageSource.MESSAGE_SOURCE_TEXT,
        optimizePrompt: promptOptimizer,
      ),
    ));
  }

  Stream<ConnectProgress> connectProvider(String providerId, String apiKey) {
    return _stub.connectProvider(
      ConnectRequest(providerId: providerId, apiKey: apiKey),
    );
  }

  void clearChat() {
    currentConversationId = DateTime.now().toIso8601String();
    messages.clear();
    _openChatStream();
    notifyListeners();
  }

  Future<ChatHistoryList> chatHistory() => _stub.getChatHistory(Empty());

  Future<void> loadChat(String id) async {
    final transcript = await _stub.getChatSession(ChatSessionId(id: id));
    currentConversationId = id;
    messages
      ..clear()
      ..addAll(transcript.messages.map((m) => ChatMessage(m.role, m.text)));
    _openChatStream();
    await refresh();
  }

  Future<void> deleteChat(String id) async {
    await _stub.deleteChatSession(ChatSessionId(id: id));
    if (id == currentConversationId) clearChat();
  }

  Future<void> setPermissionMode(PermissionMode mode) async {
    runtimeStatus = await _stub.setPermissionMode(SetPermissionModeRequest(
      mode: mode,
      conversationId: currentConversationId,
    ));
    notifyListeners();
  }

  void answerConfirmation(ConfirmDecision decision) {
    final request = pendingConfirmation;
    if (request == null || _outgoing == null) return;
    _outgoing!.add(ClientEvent(
      confirm:
          ConfirmResponse(requestId: request.requestId, decision: decision),
    ));
    pendingConfirmation = null;
    notifyListeners();
  }

  Future<void> selectProvider(String providerId) async {
    await _stub.selectProvider(ProviderId(id: providerId));
    await refresh();
  }

  Future<void> selectModel(String providerId, String modelId) async {
    await _stub.selectModel(
      SelectModelRequest(providerId: providerId, modelId: modelId),
    );
    await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnect?.cancel();
    _reconnect = null;
    _incoming?.cancel();
    _outgoing?.close();
    _channel.shutdown();
    super.dispose();
  }
}
