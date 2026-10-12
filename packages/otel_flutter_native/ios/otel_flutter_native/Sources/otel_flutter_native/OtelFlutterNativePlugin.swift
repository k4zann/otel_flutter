import Flutter
import UIKit

/// Reports how previous processes ended. MetricKit delivers crash
/// diagnostics on its own schedule (iOS 15+: shortly after the next launch;
/// iOS 14: in a daily batch), so they are stored until Dart asks with
/// `getPendingCrashes`.
public class OtelFlutterNativePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "otel_flutter_native", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(OtelFlutterNativePlugin(), channel: channel)
    if #available(iOS 14.0, *) {
      CrashDiagnostics.shared.subscribe()
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "getPendingCrashes" else {
      result(FlutterMethodNotImplemented)
      return
    }
    CrashStore.shared.take { records in
      DispatchQueue.main.async { result(records) }
    }
  }
}
