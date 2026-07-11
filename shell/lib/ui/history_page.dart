import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../ipc/agent_client.dart';
import '../main.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.ipc});
  final AgentIpc ipc;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late Future<ChatHistoryList> _history = widget.ipc.chatHistory();

  void _reload() => setState(() => _history = widget.ipc.chatHistory());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: myosBg,
      appBar: AppBar(
        backgroundColor: myosBg,
        title: const Text('Chat history'),
        actions: [
          IconButton(
            tooltip: 'New chat',
            onPressed: () {
              widget.ipc.clearChat();
              Navigator.pop(context);
            },
            icon: const Icon(Icons.add_comment_outlined),
          ),
        ],
      ),
      body: FutureBuilder<ChatHistoryList>(
        future: _history,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final sessions = snapshot.data!.sessions;
          if (sessions.isEmpty) {
            return const Center(child: Text('No conversations yet.'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: sessions.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final session = sessions[index];
              final updated = session.hasLastUpdated()
                  ? DateTime.fromMillisecondsSinceEpoch(
                      session.lastUpdated.seconds.toInt() * 1000,
                    )
                  : null;
              return ListTile(
                leading: const Icon(Icons.chat_bubble_outline),
                title: Text(
                  session.preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text([
                  '${session.messageCount} messages',
                  if (updated != null)
                    DateFormat('d MMM, HH:mm').format(updated),
                ].join(' · ')),
                selected: session.id == widget.ipc.currentConversationId,
                onTap: () async {
                  await widget.ipc.loadChat(session.id);
                  if (context.mounted) Navigator.pop(context);
                },
                trailing: IconButton(
                  tooltip: 'Delete conversation',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await widget.ipc.deleteChat(session.id);
                    _reload();
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}
