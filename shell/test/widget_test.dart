import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:myos_shell/ipc/agent_client.dart';
import 'package:myos_shell/main.dart';

void main() {
  testWidgets('shell renders the greeting', (WidgetTester tester) async {
    final ipc = AgentIpc();
    await tester.pumpWidget(MyOSShell(ipc: ipc));
    expect(find.textContaining('anything'), findsWidgets);
    // Unmount so the status-bar clock timer is cancelled before teardown.
    await tester.pumpWidget(const SizedBox());
    ipc.dispose();
  });
}
