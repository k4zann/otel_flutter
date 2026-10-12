/// Attribute value rules shared by spans, logs, metrics and the resource.
///
/// OpenTelemetry allows String, bool, int, double and homogeneous lists of
/// those. Anything else is converted with `toString()` instead of throwing,
/// because telemetry must never crash the app.
abstract final class AttributeValues {
  /// Returns a value safe to store, or null when [value] should be ignored.
  ///
  /// Lists are copied, so later mutation by the caller can't leak into
  /// already-recorded telemetry.
  static Object? normalize(Object? value, int? maxLength) {
    if (value == null) return null;
    if (value is String) return _truncate(value, maxLength);
    if (value is bool || value is int || value is double) return value;
    if (value is List<String>) {
      return List<String>.unmodifiable(
        maxLength == null ? value : value.map((s) => _truncate(s, maxLength)),
      );
    }
    if (value is List<bool>) return List<bool>.unmodifiable(value);
    if (value is List<int>) return List<int>.unmodifiable(value);
    if (value is List<double>) return List<double>.unmodifiable(value);
    if (value is List) return _normalizeUntypedList(value, maxLength);
    if (value is Enum) return value.name;
    return _truncate(value.toString(), maxLength);
  }

  /// `[1, 2]` written inline is `List<int>`, but `List<Object>` built at
  /// runtime is common too; accept it when its elements share one type.
  static Object? _normalizeUntypedList(List<Object?> list, int? maxLength) {
    final items = list.whereType<Object>().toList(growable: false);
    if (items.isEmpty) return const <String>[];
    if (items.every((e) => e is String)) {
      return List<String>.unmodifiable(
        items.map((e) => _truncate(e as String, maxLength)),
      );
    }
    if (items.every((e) => e is bool)) {
      return List<bool>.unmodifiable(items.cast<bool>());
    }
    if (items.every((e) => e is int)) {
      return List<int>.unmodifiable(items.cast<int>());
    }
    if (items.every((e) => e is num)) {
      return List<double>.unmodifiable(items.map((e) => (e as num).toDouble()));
    }
    return List<String>.unmodifiable(
      items.map((e) => _truncate(e.toString(), maxLength)),
    );
  }

  static String _truncate(String s, int? maxLength) =>
      maxLength == null || s.length <= maxLength
          ? s
          : s.substring(0, maxLength);
}

/// A bounded attribute map that counts what it had to drop.
final class AttributeMap {
  AttributeMap(this._maxCount, this._maxLength);

  final int _maxCount;
  final int? _maxLength;
  final Map<String, Object> values = <String, Object>{};
  int dropped = 0;

  void set(String key, Object? value) {
    if (key.isEmpty) return;
    final normalized = AttributeValues.normalize(value, _maxLength);
    if (normalized == null) return;
    if (values.length >= _maxCount && !values.containsKey(key)) {
      dropped++;
      return;
    }
    values[key] = normalized;
  }

  void setAll(Map<String, Object?>? attributes) {
    if (attributes == null) return;
    attributes.forEach(set);
  }
}
