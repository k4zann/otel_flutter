import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart';

import '../core/pipeline.dart';
import '../sdk.dart';
import '../trace/span.dart';
import '../trace/tracer.dart';

/// Tracks the visible screen: one `screen <name>` span per visit, measuring
/// foreground time only (the span ends when the app goes to background and a
/// new one starts on return).
@internal
final class ScreenTracker {
  ScreenTracker._();

  static final ScreenTracker instance = ScreenTracker._();

  final Tracer _tracer = Tracer.of('otel_flutter.navigation');
  String? _name;
  Span? _span;

  String? get current => _name;

  void show(String name) {
    if (name == _name && (_span != null || _suspended)) return;
    _span?.end();
    _name = name;
    OtelSdk.currentScreen = name;
    if (Pipeline.current case final OtelSdk sdk) sdk.saveCrashContext();
    // Shown while in the background (e.g. a deep link before `resumed`):
    // current at once, but the span waits for resume() so it measures
    // foreground time only.
    _span = _suspended ? null : _start(name);
  }

  /// Read from the SDK rather than remembered here, so it cannot stay set
  /// after a shutdown in the background and a later init.
  static bool get _suspended {
    final sdk = Pipeline.current;
    return sdk is OtelSdk && sdk.isInBackground;
  }

  /// App went to background.
  void suspend() {
    _span?.end();
    _span = null;
  }

  /// App came back to foreground.
  void resume() {
    final name = _name;
    if (name != null && _span == null) _span = _start(name);
  }

  Span _start(String name) => _tracer.startSpan(
    'screen $name',
    newRoot: true,
    attributes: {'app.screen.name': name},
  );

  @visibleForTesting
  void reset() {
    _span = null;
    _name = null;
    OtelSdk.currentScreen = null;
  }
}

/// Add to `MaterialApp.navigatorObservers` (or `GoRouter(observers: ...)`)
/// to get screen-view spans and `app.screen.name` on all telemetry.
///
/// Use one instance per navigator. By default only page routes count as
/// screens (dialogs and bottom sheets don't) and the screen name is
/// `RouteSettings.name`, so give your routes names.
class OtelNavigatorObserver extends NavigatorObserver {
  OtelNavigatorObserver({
    bool Function(Route<dynamic> route)? routeFilter,
    String? Function(Route<dynamic> route)? screenName,
  }) : _filter = routeFilter ?? _isPage,
       _nameOf = screenName ?? _settingsName;

  final bool Function(Route<dynamic> route) _filter;
  final String? Function(Route<dynamic> route) _nameOf;

  static bool _isPage(Route<dynamic> route) => route is PageRoute;
  static String? _settingsName(Route<dynamic> route) => route.settings.name;

  String? _screenOf(Route<dynamic>? route) {
    if (route == null || !_filter(route)) return null;
    return _nameOf(route) ?? 'unnamed';
  }

  void _show(Route<dynamic>? route) {
    final name = _screenOf(route);
    if (name != null) ScreenTracker.instance.show(name);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _show(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _show(previousRoute);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null && newRoute.isCurrent) _show(newRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // Only matters if the removed route was the one on screen.
    final removed = _screenOf(route);
    if (removed != null && removed == ScreenTracker.instance.current) {
      _show(previousRoute);
    }
  }
}
