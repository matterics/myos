import 'package:flutter/material.dart';

import 'ipc/agent_client.dart';
import 'ui/home_screen.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(MyOSShell(ipc: AgentIpc()));
}

const myosAccent = Color(0xFF7C5CFF);
const myosBg = Color(0xFF0B0E14);
const myosSurface = Color(0xFF141824);

class MyOSShell extends StatelessWidget {
  const MyOSShell({super.key, required this.ipc});
  final AgentIpc ipc;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyOS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: myosAccent,
          brightness: Brightness.dark,
          surface: myosSurface,
        ),
        scaffoldBackgroundColor: myosBg,
        fontFamily: 'Noto Sans',
        useMaterial3: true,
      ),
      home: HomeScreen(ipc: ipc),
    );
  }
}
