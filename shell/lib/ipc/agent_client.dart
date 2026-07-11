import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:grpc/grpc.dart';

import '../gen/agent.pbgrpc.dart';
import '../gen/google/protobuf/empty.pb.dart';

export '../gen/agent.pbgrpc.dart';

/// A single chat message rendered by the UI.
class ChatMessage {
  ChatMessage(this.role, this.text, {this.streaming = false, this.isError = false});
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

  String get agentName => profile?.agentName.isNotEmpty == true ? profile!.agentName : 'MyOS';

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
  void _scheduleReconnect() {
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
    } on Object {
      daemonUp = false;
    }
    notifyListeners();
  }

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
        break;
      default:
        break;
    }
    notifyListeners();
  }

  void send(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty || busy || _outgoing == null) return;
    messages.add(ChatMessage('user', trimmed));
    busy = true;
    notifyListeners();
    _outgoing!.add(ClientEvent(
      message: UserMessage(
        conversationId: 'default',
        text: trimmed,
        source: MessageSource.MESSAGE_SOURCE_TEXT,
      ),
    ));
  }

  Stream<ConnectProgress> connectProvider(String providerId, String apiKey) {
    return _stub.connectProvider(
      ConnectRequest(providerId: providerId, apiKey: apiKey),
    );
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
    _incoming?.cancel();
    _outgoing?.close();
    _channel.shutdown();
    super.dispose();
  }
}
