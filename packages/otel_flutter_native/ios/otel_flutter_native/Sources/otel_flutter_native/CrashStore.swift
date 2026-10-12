import Foundation

/// Crash records waiting for Dart, kept on disk: MetricKit hands over each
/// diagnostic exactly once, and usually before Dart asks for it (or in a
/// launch where Dart never asks). [take] returns them and deletes them, so
/// each is reported once.
final class CrashStore {
  static let shared = CrashStore(
    file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("otel_flutter_native/crashes.json"))

  /// Bounded: a crash loop must not grow the file without limit.
  static let maxRecords = 20

  private let file: URL
  private let queue = DispatchQueue(label: "kz.mystartups.otel_flutter_native.store")

  init(file: URL) {
    self.file = file
  }

  func append(_ records: [[String: Any]], completion: (() -> Void)? = nil) {
    queue.async {
      var all = self.load() + records
      if all.count > Self.maxRecords { all.removeFirst(all.count - Self.maxRecords) }
      self.save(all)
      completion?()
    }
  }

  /// Hands over all stored records (oldest first) and deletes them.
  func take(_ completion: @escaping ([[String: Any]]) -> Void) {
    queue.async {
      let all = self.load()
      try? FileManager.default.removeItem(at: self.file)
      completion(all)
    }
  }

  private func load() -> [[String: Any]] {
    guard let data = try? Data(contentsOf: file),
      let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return [] }
    return records
  }

  private func save(_ records: [[String: Any]]) {
    do {
      var dir = file.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      // Crash records describe this device; don't restore them onto another one.
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try? dir.setResourceValues(values)
      let data = try JSONSerialization.data(withJSONObject: records)
      try data.write(to: file, options: .atomic)
    } catch {
      // Nothing to report to: losing a crash record must not crash the app.
    }
  }
}
