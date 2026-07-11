import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../ipc/agent_client.dart';
import '../main.dart';
import 'loops_sheet.dart';
import 'history_page.dart';
import 'provider_sheet.dart';
import 'terminal_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.ipc});
  final AgentIpc ipc;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  bool _terminalOpen = false;
  bool _confirmationShowing = false;
  String _draft = '';

  AgentIpc get ipc => widget.ipc;

  @override
  void initState() {
    super.initState();
    ipc.addListener(_onState);
  }

  @override
  void dispose() {
    ipc.removeListener(_onState);
    super.dispose();
  }

  void _onState() {
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
      if (ipc.pendingConfirmation != null && !_confirmationShowing) {
        _showConfirmation();
      }
    });
  }

  Future<void> _showConfirmation() async {
    final request = ipc.pendingConfirmation;
    if (request == null) return;
    _confirmationShowing = true;
    final decision = await showDialog<ConfirmDecision>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: myosSurface,
        title: Text(request.title),
        content: SelectableText(request.detail),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(context, ConfirmDecision.CONFIRM_DECISION_DENY),
            child: const Text('Deny'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(
                context, ConfirmDecision.CONFIRM_DECISION_ALLOW_ALWAYS),
            child: const Text('Auto accept this session'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
                context, ConfirmDecision.CONFIRM_DECISION_ALLOW_ONCE),
            child: const Text('Allow once'),
          ),
        ],
      ),
    );
    _confirmationShowing = false;
    ipc.answerConfirmation(decision ?? ConfirmDecision.CONFIRM_DECISION_DENY);
  }

  void _send() {
    ipc.send(_input.text);
    _input.clear();
    _draft = '';
    _inputFocus.requestFocus();
  }

  void _toggleTerminal() {
    if (_terminalOpen) {
      Navigator.of(context).pop();
    } else {
      _terminalOpen = true;
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const TerminalScreen()))
          .then((_) => _terminalOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyT,
            control: true, shift: true): _toggleTerminal,
        const SingleActivator(LogicalKeyboardKey.keyT, meta: true, shift: true):
            _toggleTerminal,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF0B0E14),
                  Color(0xFF121026),
                  Color(0xFF0B0E14)
                ],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  _StatusBar(ipc: ipc),
                  Expanded(
                    child: ipc.messages.isEmpty
                        ? _Greeting(ipc: ipc)
                        : _Conversation(ipc: ipc, scroll: _scroll),
                  ),
                  _chatBar(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chatBar(BuildContext context) {
    final provider = ipc.selectedProvider;
    final modelName = () {
      final m = ipc.models;
      if (m == null) return null;
      for (final model in m.models) {
        if (model.id == m.selectedModelId) return model.displayName;
      }
      return m.selectedModelId.isEmpty ? null : m.selectedModelId;
    }();

    return Container(
      constraints: const BoxConstraints(maxWidth: 860),
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            alignment: WrapAlignment.center,
            runSpacing: 8,
            children: [
              _Chip(
                icon: Icons.bolt,
                label: provider == null
                    ? 'Connect provider'
                    : provider.displayName,
                highlighted: provider == null,
                onTap: () => showProviderSheet(context, ipc),
              ),
              if (provider != null && ipc.models != null) ...[
                const SizedBox(width: 8),
                _modelChip(provider, modelName),
                const SizedBox(width: 8),
                _Chip(
                  icon: Icons.delete_outline,
                  label: 'Clear Chat',
                  onTap: () => ipc.clearChat(),
                ),
              ],
              const SizedBox(width: 8),
              _Chip(
                icon: Icons.all_inclusive,
                label: ipc.loops?.loops.isEmpty ?? true
                    ? 'Loops'
                    : 'Loops (${ipc.loops!.loops.length})',
                onTap: () => showLoopsSheet(context, ipc),
              ),
              const SizedBox(width: 8),
              _Chip(
                icon: Icons.history,
                label: 'History',
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => HistoryPage(ipc: ipc),
                )),
              ),
              const SizedBox(width: 8),
              _permissionChip(),
              const SizedBox(width: 8),
              _Chip(
                icon: Icons.auto_fix_high,
                label: ipc.promptOptimizer ? 'Optimize on' : 'Optimize off',
                highlighted: ipc.promptOptimizer,
                onTap: () => ipc.send('/optimize'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_draft.startsWith('/') && ipc.providerCommands != null)
            _commandSuggestions(),
          Container(
            decoration: BoxDecoration(
              color: myosSurface,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.white12),
              boxShadow: const [
                BoxShadow(
                    color: Colors.black45,
                    blurRadius: 24,
                    offset: Offset(0, 8)),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Providers',
                  icon: Icon(Icons.bolt,
                      color: provider == null ? myosAccent : Colors.white54),
                  onPressed: () => showProviderSheet(context, ipc),
                ),
                Expanded(
                  child: TextField(
                    controller: _input,
                    focusNode: _inputFocus,
                    autofocus: true,
                    onChanged: (value) => setState(() => _draft = value),
                    onSubmitted: (_) => _send(),
                    style: const TextStyle(fontSize: 16),
                    decoration: InputDecoration(
                      hintText: 'Ask ${ipc.agentName} anything…',
                      border: InputBorder.none,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Voice arrives in a later update',
                  icon: const Icon(Icons.mic_none, color: Colors.white24),
                  onPressed: null,
                ),
                IconButton(
                  tooltip: 'Send',
                  icon: ipc.busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_upward, color: myosAccent),
                  onPressed: ipc.busy ? null : _send,
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Ctrl+Shift+T — terminal',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.25), fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _modelChip(Provider provider, String? modelName) {
    final models = ipc.models!;
    return PopupMenuButton<String>(
      tooltip: 'Select model',
      color: myosSurface,
      onSelected: (id) => ipc.selectModel(provider.id, id),
      itemBuilder: (_) => [
        for (final m in models.models)
          PopupMenuItem(
            value: m.id,
            child: Row(
              children: [
                Icon(
                  m.id == models.selectedModelId
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 16,
                  color: myosAccent,
                ),
                const SizedBox(width: 8),
                Text(m.displayName),
              ],
            ),
          ),
      ],
      child: _Chip(
        icon: Icons.memory,
        label: modelName ?? 'Model',
        trailing: Icons.expand_more,
      ),
    );
  }

  Widget _permissionChip() {
    final mode = ipc.runtimeStatus?.permissionMode;
    final label = mode == PermissionMode.PERMISSION_MODE_FULL_ACCESS
        ? 'Full access'
        : mode == PermissionMode.PERMISSION_MODE_AUTO_SESSION
            ? 'Auto this session'
            : 'Ask approval';
    return PopupMenuButton<PermissionMode>(
      tooltip: 'Agent access',
      color: myosSurface,
      onSelected: ipc.setPermissionMode,
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: PermissionMode.PERMISSION_MODE_ASK,
          child: Text('Ask for approval'),
        ),
        PopupMenuItem(
          value: PermissionMode.PERMISSION_MODE_AUTO_SESSION,
          child: Text('Auto accept this session'),
        ),
        PopupMenuItem(
          value: PermissionMode.PERMISSION_MODE_FULL_ACCESS,
          child: Text('Full access'),
        ),
      ],
      child: _Chip(icon: Icons.shield_outlined, label: label),
    );
  }

  Widget _commandSuggestions() {
    final commands = ipc.providerCommands!.commands
        .where((command) => command.name.startsWith(_draft))
        .take(6);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: myosSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final command in commands)
            ActionChip(
              label: Text('${command.name} — ${command.description}'),
              onPressed: () {
                _input.text = command.name;
                _input.selection = TextSelection.collapsed(
                  offset: _input.text.length,
                );
                setState(() => _draft = command.name);
              },
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    this.trailing,
    this.onTap,
    this.highlighted = false,
  });
  final IconData icon;
  final String label;
  final IconData? trailing;
  final VoidCallback? onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color:
              highlighted ? myosAccent.withValues(alpha: 0.25) : Colors.white10,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: highlighted ? myosAccent : Colors.white12, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 14, color: highlighted ? myosAccent : Colors.white70),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
            if (trailing != null) ...[
              const SizedBox(width: 4),
              Icon(trailing, size: 14, color: Colors.white38),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends StatefulWidget {
  const _StatusBar({required this.ipc});
  final AgentIpc ipc;

  @override
  State<_StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<_StatusBar> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.blur_on, color: myosAccent, size: 18),
          const SizedBox(width: 8),
          Text(
            'MyOS',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color:
                  widget.ipc.daemonUp ? Colors.greenAccent : Colors.redAccent,
            ),
          ),
          if (widget.ipc.runtimeStatus != null) ...[
            const SizedBox(width: 12),
            Icon(
              Icons.memory,
              size: 14,
              color: widget.ipc.runtimeStatus!.modelAvailable
                  ? Colors.greenAccent
                  : Colors.orangeAccent,
            ),
            const SizedBox(width: 4),
            Text(
              '${(widget.ipc.runtimeStatus!.contextUsedTokens.toDouble() / 1000).toStringAsFixed(1)}k / '
              '${(widget.ipc.runtimeStatus!.contextWindowTokens.toDouble() / 1000).toStringAsFixed(0)}k context',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 12,
              ),
            ),
          ],
          const Spacer(),
          Text(
            DateFormat('EEE d MMM  HH:mm').format(now),
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6), fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.ipc});
  final AgentIpc ipc;

  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final salutation = hour < 5
        ? 'Good night'
        : hour < 12
            ? 'Good morning'
            : hour < 18
                ? 'Good afternoon'
                : 'Good evening';
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.blur_on, color: myosAccent, size: 64),
          const SizedBox(height: 20),
          Text(
            '$salutation.',
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w300),
          ),
          const SizedBox(height: 6),
          Text(
            'Ask ${ipc.agentName} anything.',
            style: TextStyle(
              fontSize: 16,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
          if (ipc.selectedProvider == null) ...[
            const SizedBox(height: 24),
            Text(
              'Connect an AI provider to get started  →  ⚡',
              style: TextStyle(
                fontSize: 13,
                color: myosAccent.withValues(alpha: 0.9),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Conversation extends StatelessWidget {
  const _Conversation({required this.ipc, required this.scroll});
  final AgentIpc ipc;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: ListView.builder(
          controller: scroll,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          itemCount: ipc.messages.length,
          itemBuilder: (context, i) {
            final m = ipc.messages[i];
            final isUser = m.role == 'user';
            return Align(
              alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                constraints: const BoxConstraints(maxWidth: 640),
                decoration: BoxDecoration(
                  color: m.isError
                      ? Colors.red.withValues(alpha: 0.15)
                      : isUser
                          ? myosAccent.withValues(alpha: 0.22)
                          : myosSurface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: m.isError ? Colors.redAccent : Colors.white10,
                  ),
                ),
                child: SelectableText(
                  m.text.isEmpty && m.streaming ? '…' : m.text,
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.45,
                    color: m.isError
                        ? Colors.redAccent
                        : Colors.white.withValues(alpha: 0.92),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
