import 'dart:async';

import '../trace/span.dart';

/// Immutable execution context: the active span plus W3C baggage.
///
/// It travels through `async`/`await`, timers and streams via Dart [Zone]s,
/// so a span made active with [run] is visible to everything started inside.
final class OtelContext {
  const OtelContext._(this.span, this.baggage);

  /// Empty context: no active span, no baggage.
  static const OtelContext root = OtelContext._(null, <String, String>{});

  static final Object _zoneKey = Object();

  /// The context active in the current zone.
  static OtelContext get current =>
      Zone.current[_zoneKey] as OtelContext? ?? root;

  /// The active span, or null when none is active.
  final Span? span;

  /// W3C baggage entries carried with this context.
  final Map<String, String> baggage;

  OtelContext withSpan(Span? span) => OtelContext._(span, baggage);

  OtelContext withBaggage(Map<String, String> baggage) =>
      OtelContext._(span, Map<String, String>.unmodifiable(baggage));

  /// Runs [fn] with this context active. Works for sync and async [fn]:
  /// everything scheduled inside inherits the context.
  R run<R>(R Function() fn) => runZoned(fn, zoneValues: {_zoneKey: this});
}
