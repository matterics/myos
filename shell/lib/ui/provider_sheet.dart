import 'package:flutter/material.dart';

import '../ipc/agent_client.dart';
import '../main.dart';

void showProviderSheet(BuildContext context, AgentIpc ipc) {
  showModalBottomSheet(
    context: context,
    backgroundColor: myosSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _ProviderSheet(ipc: ipc),
  );
}

class _ProviderSheet extends StatefulWidget {
  const _ProviderSheet({required this.ipc});
  final AgentIpc ipc;

  @override
  State<_ProviderSheet> createState() => _ProviderSheetState();
}

class _ProviderSheetState extends State<_ProviderSheet> {
  @override
  void initState() {
    super.initState();
    widget.ipc.addListener(_onState);
  }

  @override
  void dispose() {
    widget.ipc.removeListener(_onState);
    super.dispose();
  }

  void _onState() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final providers = widget.ipc.providers;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'AI providers',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Connect a provider, then pick which one answers you.',
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 16),
            if (providers == null)
              const Center(child: CircularProgressIndicator())
            else
              for (final p in providers.providers)
                _providerTile(context, p,
                    selected: p.id == providers.selectedProviderId),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _providerTile(BuildContext context, Provider p,
      {required bool selected}) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: Icon(
        selected
            ? Icons.radio_button_checked
            : p.connected
                ? Icons.radio_button_off
                : Icons.link_off,
        color: selected ? myosAccent : Colors.white38,
      ),
      title: Text(p.displayName),
      subtitle: Text(
        p.connected ? (selected ? 'Active' : 'Connected') : 'Not connected',
        style: TextStyle(
          fontSize: 12,
          color: p.connected
              ? Colors.greenAccent.withValues(alpha: 0.8)
              : Colors.white38,
        ),
      ),
      trailing: p.connected
          ? TextButton(
              onPressed:
                  selected ? null : () => widget.ipc.selectProvider(p.id),
              child: Text(selected ? 'Selected' : 'Use'),
            )
          : FilledButton.tonal(
              onPressed: () => _connectDialog(context, p),
              child: const Text('Connect'),
            ),
      onTap: p.connected && !selected
          ? () => widget.ipc.selectProvider(p.id)
          : null,
    );
  }

  Future<void> _connectDialog(BuildContext context, Provider p) async {
    final keyController = TextEditingController();
    String? status;
    bool working = false;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialog) => AlertDialog(
          backgroundColor: myosSurface,
          title: Text('Connect ${p.displayName}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: keyController,
                obscureText: true,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'API key',
                  hintText: 'Paste your API key',
                  border: OutlineInputBorder(),
                ),
              ),
              if (status != null) ...[
                const SizedBox(height: 12),
                Text(
                  status!,
                  style: TextStyle(
                    fontSize: 13,
                    color: status!.startsWith('✓')
                        ? Colors.greenAccent
                        : status!.startsWith('✗')
                            ? Colors.redAccent
                            : Colors.white70,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: working
                  ? null
                  : () async {
                      setDialog(() {
                        working = true;
                        status = 'Validating…';
                      });
                      try {
                        await for (final progress in widget.ipc
                            .connectProvider(p.id, keyController.text.trim())) {
                          if (progress.state ==
                              ConnectState.CONNECT_STATE_CONNECTED) {
                            setDialog(() => status = '✓ Connected');
                            await widget.ipc.refresh();
                            if (dialogContext.mounted) {
                              await Future<void>.delayed(
                                  const Duration(milliseconds: 500));
                              if (dialogContext.mounted) {
                                Navigator.of(dialogContext).pop();
                              }
                            }
                          } else if (progress.state ==
                              ConnectState.CONNECT_STATE_FAILED) {
                            setDialog(() {
                              working = false;
                              status = '✗ ${progress.message}';
                            });
                          } else {
                            setDialog(() => status = progress.message);
                          }
                        }
                      } on Object catch (e) {
                        setDialog(() {
                          working = false;
                          status = '✗ $e';
                        });
                      }
                    },
              child: const Text('Connect'),
            ),
          ],
        ),
      ),
    );
  }
}
