import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Test harness for the native side: shows what `getPendingCrashes` returns.
///
/// Crash the app (e.g. `adb shell am crash <package>`), relaunch, and the
/// records appear here once; "Check again" must then return nothing.
/// The demo of the full integration is the repository's `example/` app.
const _channel = MethodChannel('otel_flutter_native');

/// Crash/hang triggers implemented in the harness app's native code.
const _harness = MethodChannel('harness');

void main() => runApp(const HarnessApp());

class HarnessApp extends StatefulWidget {
  const HarnessApp({super.key});

  @override
  State<HarnessApp> createState() => _HarnessAppState();
}

class _HarnessAppState extends State<HarnessApp> {
  final List<String> _results = [];

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    String text;
    try {
      final records = await _channel.invokeListMethod<Object?>(
        'getPendingCrashes',
      );
      text = const JsonEncoder.withIndent('  ').convert(records);
    } on Object catch (e) {
      text = 'error: $e';
    }
    // Readable with `adb logcat -s flutter` / the iOS system log.
    debugPrint('getPendingCrashes -> $text');
    if (mounted) setState(() => _results.insert(0, text));
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('otel_flutter_native harness')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _check,
        label: const Text('Check again'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => _harness.invokeMethod<void>('crash'),
                child: const Text('Native crash'),
              ),
              OutlinedButton(
                onPressed: () => _harness.invokeMethod<void>('signal'),
                child: const Text('SIGSEGV'),
              ),
              OutlinedButton(
                onPressed: () => _harness.invokeMethod<void>('hang'),
                child: const Text('Hang main thread'),
              ),
            ],
          ),
          for (final r in _results)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(
                  r,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
