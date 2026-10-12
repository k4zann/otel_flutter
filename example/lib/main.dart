import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:otel_flutter/otel_flutter.dart';
import 'package:path_provider/path_provider.dart';

/// Where telemetry goes. Override with
/// `--dart-define=OTEL_EXPORTER_OTLP_ENDPOINT=https://...`.
String endpoint() {
  const fromDefine = String.fromEnvironment('OTEL_EXPORTER_OTLP_ENDPOINT');
  if (fromDefine.isNotEmpty) return fromDefine;
  // The Android emulator reaches your computer at 10.0.2.2; the iOS
  // simulator, macOS and web can use localhost.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return 'http://10.0.2.2:4318';
  }
  return 'http://localhost:4318';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Otel.init(
    OtelConfig(
      serviceName: 'otel-flutter-example',
      serviceVersion: '1.0.0',
      environment: kReleaseMode ? 'production' : 'development',
      endpoint: endpoint(),
      // Keeps unsent data on disk while offline (not available on web).
      offlineStorageDirectory: kIsWeb
          ? null
          : (await getApplicationSupportDirectory()).path,
      debug: true,
    ),
  );
  runApp(const ExampleApp());
}

final tracer = Otel.tracer('example');
final logger = Otel.logger('example');
final clicks = Otel.meter('example').counter('example.button.clicks');
final api = OtelHttpClient();

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'otel_flutter example',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    navigatorObservers: [OtelNavigatorObserver()],
    routes: {
      '/': (_) => const HomeScreen(),
      '/details': (_) => const DetailsScreen(),
    },
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _status = 'Tap a button, then look at your backend.';

  void _show(String s) => setState(() => _status = s);

  Future<void> _tracedWork() async {
    clicks.add(1, {'button': 'traced_work'});
    await tracer.traceAsync('load_profile', (span) async {
      span.setAttribute('profile.source', 'cache');
      await tracer.traceAsync('read_cache', (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 40));
      });
      await tracer.traceAsync('decode', (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 15));
      });
      logger.info('Profile loaded', attributes: {'items': 3});
    });
    _show('Created a trace with 3 spans and a correlated log.');
  }

  Future<void> _httpRequest() async {
    clicks.add(1, {'button': 'http'});
    try {
      final r = await api.get(
        Uri.parse('https://jsonplaceholder.typicode.com/todos/1'),
      );
      _show('HTTP ${r.statusCode}: traced, with traceparent header.');
    } catch (e) {
      _show('HTTP failed (also traced): $e');
    }
  }

  void _caughtError() {
    clicks.add(1, {'button': 'caught_error'});
    try {
      int.parse('not a number');
    } catch (e, st) {
      Otel.recordError(e, st, attributes: {'feature': 'parsing'});
      _show('Reported a caught FormatException.');
    }
  }

  void _uncaughtError() {
    clicks.add(1, {'button': 'uncaught_error'});
    // Reaches PlatformDispatcher.onError and is captured automatically.
    unawaited(Future<void>(() => throw StateError('Uncaught async error')));
    _show('Threw an uncaught async error.');
  }

  void _jank() {
    clicks.add(1, {'button': 'jank'});
    // Blocks the UI thread: shows up as a frozen frame + app.jank event.
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < 800) {}
    _show('Blocked the UI thread for 800 ms.');
  }

  Future<void> _flush() async {
    await Otel.flush();
    _show('Flushed everything buffered.');
  }

  @override
  Widget build(BuildContext context) {
    final buttons = <(String, IconData, VoidCallback)>[
      ('Traced work', Icons.timeline, _tracedWork),
      ('HTTP request', Icons.cloud_download, _httpRequest),
      (
        'Open details screen',
        Icons.open_in_new,
        () => Navigator.pushNamed(context, '/details'),
      ),
      ('Caught error', Icons.report, _caughtError),
      ('Uncaught error', Icons.bug_report, _uncaughtError),
      ('Jank (800 ms)', Icons.slow_motion_video, _jank),
      ('Flush now', Icons.send, _flush),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('otel_flutter')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_status, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'session: ${Otel.sessionId}\nscreen: ${Otel.currentScreen}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          for (final (label, icon, onTap) in buttons)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FilledButton.tonalIcon(
                onPressed: onTap,
                icon: Icon(icon),
                label: Text(label),
              ),
            ),
        ],
      ),
    );
  }
}

class DetailsScreen extends StatelessWidget {
  const DetailsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Details')),
    body: const Center(
      child: Text('Time spent here is a "screen /details" span.'),
    ),
  );
}
