import Foundation
import MetricKit

/// Receives MetricKit crash diagnostics (only reads what the OS recorded:
/// no signal handlers, so other crash reporters are unaffected).
@available(iOS 14.0, *)
final class CrashDiagnostics: NSObject, MXMetricManagerSubscriber {
  static let shared = CrashDiagnostics()

  private var subscribed = false

  /// Once per process, even with several Flutter engines.
  func subscribe() {
    guard !subscribed else { return }
    subscribed = true
    MXMetricManager.shared.add(self)
  }

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    let records = payloads.flatMap { payload in
      (payload.crashDiagnostics ?? []).map { CrashRecord.from($0, time: payload.timeStampEnd) }
    }
    if !records.isEmpty { CrashStore.shared.append(records) }
  }
}

/// Converts a crash diagnostic into the channel's record format, shared with
/// Android: `{reason, time (ms), description?, type?, message?, stack?}`.
enum CrashRecord {
  @available(iOS 14.0, *)
  static func from(_ diagnostic: MXCrashDiagnostic, time: Date) -> [String: Any] {
    var objcName: String?
    var objcMessage: String?
    if #available(iOS 17.0, *), let reason = diagnostic.exceptionReason {
      objcName = reason.exceptionName
      objcMessage = reason.composedMessage
    }
    return make(
      signal: diagnostic.signal?.intValue,
      exceptionType: diagnostic.exceptionType?.intValue,
      exceptionCode: diagnostic.exceptionCode?.intValue,
      terminationReason: diagnostic.terminationReason,
      objcExceptionName: objcName,
      objcExceptionMessage: objcMessage,
      callStackTree: diagnostic.callStackTree.jsonRepresentation(),
      time: time)
  }

  /// An uncaught Objective-C exception is the counterpart of a JVM crash
  /// (`crash`); everything else ended in a signal (`native_crash`).
  static func make(
    signal: Int?,
    exceptionType: Int?,
    exceptionCode: Int?,
    terminationReason: String?,
    objcExceptionName: String?,
    objcExceptionMessage: String?,
    callStackTree: Data,
    time: Date
  ) -> [String: Any] {
    let signalName = signal.map { signalNames[$0] ?? "SIG\($0)" }
    let machName = exceptionType.map { machExceptionNames[$0] ?? "EXC_\($0)" }
    let machText = machName.map { name in exceptionCode.map { "\(name) (code \($0))" } ?? name }

    var record: [String: Any] = [
      "reason": objcExceptionName == nil ? "native_crash" : "crash",
      "time": Int64((time.timeIntervalSince1970 * 1000).rounded()),
    ]
    record["description"] = terminationReason
    record["type"] = objcExceptionName ?? signalName ?? machName
    let summary = [machText, signalName].compactMap { $0 }.joined(separator: ", ")
    record["message"] = objcExceptionMessage ?? (summary.isEmpty ? nil : summary)
    record["stack"] = crashedThread(callStackTree)
    return record
  }

  /// The tree has every thread; keep the one the crash is attributed to (as
  /// on Android), which keeps the record small. Frames carry `binaryUUID`
  /// and offsets for later symbolication.
  static func crashedThread(_ tree: Data) -> String? {
    if var json = try? JSONSerialization.jsonObject(with: tree) as? [String: Any],
      let stacks = json["callStacks"] as? [[String: Any]]
    {
      let attributed = stacks.filter { $0["threadAttributed"] as? Bool == true }
      if !attributed.isEmpty {
        json["callStacks"] = attributed
        if let data = try? JSONSerialization.data(withJSONObject: json, options: .sortedKeys) {
          return String(data: data, encoding: .utf8)
        }
      }
    }
    return String(data: tree, encoding: .utf8)
  }

  /// Darwin numbering (differs from Linux for SIGBUS, SIGSYS, ...).
  static let signalNames: [Int: String] = [
    1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT",
    7: "SIGEMT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 12: "SIGSYS",
    13: "SIGPIPE", 14: "SIGALRM", 15: "SIGTERM",
  ]

  static let machExceptionNames: [Int: String] = [
    1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION",
    5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 7: "EXC_SYSCALL", 8: "EXC_MACH_SYSCALL",
    9: "EXC_RPC_ALERT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD",
    13: "EXC_CORPSE_NOTIFY",
  ]
}
