import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import '../main.dart';

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key, this.initialCommand});
  final String? initialCommand;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  late final Terminal terminal;
  Pty? pty;
  String? error;

  @override
  void initState() {
    super.initState();
    terminal = Terminal(maxLines: 10000);
    _startShell();
  }

  void _startShell() {
    try {
      final shell = Platform.environment['SHELL'] ?? '/bin/bash';
      final p = Pty.start(
        shell,
        arguments: ['-l'],
        environment: {
          ...Platform.environment,
          'TERM': 'xterm-256color',
        },
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );
      pty = p;
      p.output
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(terminal.write);
      p.exitCode.then((code) {
        terminal.write('\r\n[process exited with code $code]\r\n');
      });
      terminal.onOutput = (data) => p.write(const Utf8Encoder().convert(data));
      terminal.onResize = (w, h, pw, ph) => p.resize(h, w);
      if (widget.initialCommand case final command?) {
        Future<void>.delayed(const Duration(milliseconds: 250), () {
          if (mounted) p.write(const Utf8Encoder().convert('$command\r'));
        });
      }
    } on Object catch (e) {
      setState(() => error = 'Could not start shell: $e');
    }
  }

  @override
  void dispose() {
    pty?.kill();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyT,
            control: true, shift: true): () => Navigator.of(context).pop(),
        const SingleActivator(LogicalKeyboardKey.keyT, meta: true, shift: true):
            () => Navigator.of(context).pop(),
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0C10),
        appBar: AppBar(
          backgroundColor: myosBg,
          toolbarHeight: 40,
          title: const Text('Terminal', style: TextStyle(fontSize: 14)),
          leading: IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Close (Ctrl+Shift+T)',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: error != null
            ? Center(
                child: Text(error!,
                    style: const TextStyle(color: Colors.redAccent)))
            : Padding(
                padding: const EdgeInsets.all(4),
                child: TerminalView(
                  terminal,
                  autofocus: true,
                  textStyle: const TerminalStyle(
                    fontSize: 14,
                    fontFamily: 'JetBrains Mono',
                  ),
                ),
              ),
      ),
    );
  }
}
