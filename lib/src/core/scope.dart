/// Identifies the code that produced telemetry (a library, feature or module).
///
/// Instances are canonical: [InstrumentationScope.of] returns the same object
/// for the same name/version, so exporters can group by identity.
final class InstrumentationScope {
  InstrumentationScope._(this.name, this.version);

  static final Map<String, InstrumentationScope> _cache = {};

  factory InstrumentationScope.of(String name, [String? version]) =>
      _cache.putIfAbsent(
        '$name\u0000${version ?? ''}',
        () => InstrumentationScope._(name, version),
      );

  final String name;
  final String? version;

  @override
  String toString() => version == null ? name : '$name@$version';
}
