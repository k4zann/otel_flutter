import 'package:meta/meta.dart';

/// The SDK's own console output. Quiet by default in release builds, and
/// each distinct problem is reported once instead of once per batch.
@internal
abstract final class Diagnostics {
  static const bool _isRelease = bool.fromEnvironment('dart.vm.product');

  /// Enabled by `OtelConfig.debug`: prints a line per export.
  static bool verbose = false;

  static void Function(String message) printer = print;

  static final Set<String> _warned = <String>{};

  static void debug(String message) {
    if (verbose) printer('[otel] $message');
  }

  static void warnOnce(String key, String message) {
    if ((verbose || !_isRelease) && _warned.add(key)) {
      printer('[otel] WARNING: $message');
    }
  }

  @visibleForTesting
  static void reset() {
    verbose = false;
    _warned.clear();
  }
}
