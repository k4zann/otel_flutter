/// Native crash, ANR and exit-reason reporting for `otel_flutter`.
///
/// Native crashes (Kotlin/Swift/C++, signals), Android ANRs and low-memory
/// kills end the process before any Dart code runs. This plugin reads the
/// records the OS keeps about them (Android `ApplicationExitInfo`, iOS
/// MetricKit) on the next launch.
library;
