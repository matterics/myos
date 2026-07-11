import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../ipc/agent_client.dart';
import '../main.dart';

/// Loops panel: MyOS is loop-first — standing goals that run on a cadence,
/// produce reports, and create projects.
void showLoopsSheet(BuildContext context, AgentIpc ipc) {
  ipc.refreshLoops();
  showModalBottomSheet(
    context: context,
    backgroundColor: myosSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => _LoopsSheet(ipc: ipc),
  );
}

class _LoopsSheet extends StatefulWidget {
  const _LoopsSheet({required this.ipc});
  final AgentIpc ipc;

  @override
  State<_LoopsSheet> createState() => _LoopsSheetState();
}

class _LoopsSheetState extends State<_LoopsSheet> {
  final Set<String> _running = {};

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
    final loops = widget.ipc.loops;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.all_inclusive, color: myosAccent, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    'Loops',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  FilledButton.tonalIcon(
                    onPressed: () => _createDialog(context),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('New loop'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Standing goals that run on a schedule, report back, and build projects.',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: loops == null
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    : loops.loops.isEmpty
                        ? _empty()
                        : ListView(
                            shrinkWrap: true,
                            children: [
                              for (final l in loops.loops) _loopTile(context, l),
                            ],
                          ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Column(
          children: [
            Icon(Icons.all_inclusive,
                size: 40, color: Colors.white.withValues(alpha: 0.2)),
            const SizedBox(height: 12),
            Text(
              'No loops yet.\nCreate one — it starts running within 30 seconds.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _cadence(int minutes) {
    if (minutes % 1440 == 0 && minutes >= 1440) {
      final d = minutes ~/ 1440;
      return d == 1 ? 'daily' : 'every $d days';
    }
    if (minutes % 60 == 0 && minutes >= 60) {
      final h = minutes ~/ 60;
      return h == 1 ? 'hourly' : 'every $h h';
    }
    return 'every $minutes min';
  }

  Widget _loopTile(BuildContext context, Loop l) {
    final spec = l.spec;
    final lastRun = l.hasLastRunAt()
        ? DateFormat('d MMM HH:mm').format(l.lastRunAt.toDateTime().toLocal())
        : 'never';
    final projectName = spec.projectName;
    final isRunning = _running.contains(l.id);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Switch(
            value: l.enabled,
            activeThumbColor: myosAccent,
            onChanged: (v) => widget.ipc.setLoopEnabled(l.id, v),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(spec.name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  '${_cadence(spec.intervalMinutes)} · ${l.runCount} runs · last $lastRun'
                  '${projectName.isEmpty ? '' : ' · 📁 $projectName'}',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Colors.white.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Run now',
            icon: isRunning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow, color: myosAccent),
            onPressed: isRunning ? null : () => _runNow(l),
          ),
          IconButton(
            tooltip: 'Run reports',
            icon: const Icon(Icons.receipt_long, color: Colors.white54),
            onPressed: () => _showRuns(l),
          ),
          IconButton(
            tooltip: 'Delete loop',
            icon: const Icon(Icons.delete_outline, color: Colors.white38),
            onPressed: () => _confirmDelete(context, l),
          ),
        ],
      ),
    );
  }

  Future<void> _runNow(Loop l) async {
    setState(() => _running.add(l.id));
    try {
      final run = await widget.ipc.runLoopNow(l.id);
      if (!mounted) return;
      _showReport(l.spec.name, run);
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Run failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _running.remove(l.id));
    }
  }

  Future<void> _confirmDelete(BuildContext context, Loop l) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: myosSurface,
        title: Text('Delete "${l.spec.name}"?'),
        content: const Text(
            'The loop and its run history are removed. Project files it created stay on disk.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes == true) await widget.ipc.deleteLoop(l.id);
  }

  void _showReport(String loopName, LoopRun run) {
    showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: myosSurface,
        title: Text(loopName),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: SelectableText(
              run.report.isEmpty ? '(empty report)' : run.report,
              style: const TextStyle(fontSize: 13.5, height: 1.45),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showRuns(Loop l) async {
    LoopRunList? runs;
    Object? error;
    try {
      runs = await widget.ipc.loopRuns(l.id);
    } on Object catch (e) {
      error = e;
    }
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: myosSurface,
        title: Text('${l.spec.name} — runs'),
        content: SizedBox(
          width: 560,
          height: 400,
          child: error != null
              ? Text('Failed to load runs: $error')
              : (runs == null || runs.runs.isEmpty)
                  ? const Center(child: Text('No runs yet.'))
                  : ListView(
                      children: [
                        for (final r in runs.runs) _runTile(r),
                      ],
                    ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _runTile(LoopRun r) {
    final started = r.hasStartedAt()
        ? DateFormat('d MMM HH:mm').format(r.startedAt.toDateTime().toLocal())
        : '';
    final ok = r.status == LoopRunStatus.LOOP_RUN_STATUS_SUCCEEDED;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 16,
            color: ok ? Colors.greenAccent : Colors.redAccent,
          ),
          const SizedBox(width: 8),
          Text(started, style: const TextStyle(fontSize: 13)),
        ],
      ),
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: SelectableText(
            r.report.isEmpty ? '(empty report)' : r.report,
            style: TextStyle(
              fontSize: 13,
              height: 1.45,
              color: Colors.white.withValues(alpha: 0.85),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _createDialog(BuildContext context) async {
    final name = TextEditingController();
    final goal = TextEditingController();
    final project = TextEditingController();
    int intervalMinutes = 60;
    String? status;
    bool working = false;
    const cadences = <int, String>{
      15: 'Every 15 min',
      60: 'Hourly',
      240: 'Every 4 h',
      1440: 'Daily',
    };
    await showDialog<void>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDialog) => AlertDialog(
          backgroundColor: myosSurface,
          title: const Text('New loop'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'e.g. Track voice pipeline',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: goal,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Goal — what should each run do?',
                    hintText:
                        'e.g. Assess progress, list blockers, propose the next step.',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: project,
                  decoration: const InputDecoration(
                    labelText: 'Project (optional — the loop creates it)',
                    hintText: 'e.g. Voice Pipeline',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: intervalMinutes,
                  dropdownColor: myosSurface,
                  decoration: const InputDecoration(
                    labelText: 'Cadence',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final e in cadences.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => setDialog(() => intervalMinutes = v ?? 60),
                ),
                if (status != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    status!,
                    style: const TextStyle(
                        fontSize: 13, color: Colors.redAccent),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: working
                  ? null
                  : () async {
                      if (name.text.trim().isEmpty ||
                          goal.text.trim().isEmpty) {
                        setDialog(() => status = 'Name and goal are required.');
                        return;
                      }
                      setDialog(() {
                        working = true;
                        status = null;
                      });
                      try {
                        await widget.ipc.createLoop(
                          name: name.text.trim(),
                          goal: goal.text.trim(),
                          intervalMinutes: intervalMinutes,
                          projectName: project.text.trim(),
                        );
                        if (dctx.mounted) Navigator.of(dctx).pop();
                      } on Object catch (e) {
                        setDialog(() {
                          working = false;
                          status = '$e';
                        });
                      }
                    },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }
}
