import Flutter
import UIKit
import XCTest

@testable import otel_flutter_native

class RunnerTests: XCTestCase {
  private var dir: URL!

  override func setUp() {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: dir)
  }

  private func take(_ store: CrashStore) -> [[String: Any]] {
    let done = expectation(description: "take")
    var out: [[String: Any]] = []
    store.take {
      out = $0
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
    return out
  }

  private func append(_ store: CrashStore, _ records: [[String: Any]]) {
    let done = expectation(description: "append")
    store.append(records) { done.fulfill() }
    wait(for: [done], timeout: 2)
  }

  /// Shape of `MXCallStackTree.jsonRepresentation()`, two threads.
  private let tree = """
    {"callStackPerThread":true,"callStacks":[
     {"threadAttributed":false,"callStackRootFrames":[{"binaryName":"libsystem_kernel.dylib","address":1}]},
     {"threadAttributed":true,"callStackRootFrames":[{"binaryName":"Runner","binaryUUID":"AB-12","offsetIntoBinaryTextSegment":96,"address":2}]}
    ]}
    """.data(using: .utf8)!

  func testSignalCrashRecord() {
    let record = CrashRecord.make(
      signal: 11, exceptionType: 1, exceptionCode: 0,
      terminationReason: "Namespace SIGNAL, Code 11",
      objcExceptionName: nil, objcExceptionMessage: nil,
      callStackTree: tree, time: Date(timeIntervalSince1970: 1_791_792_169.097))

    XCTAssertEqual(record["reason"] as? String, "native_crash")
    XCTAssertEqual(record["type"] as? String, "SIGSEGV")
    XCTAssertEqual(record["message"] as? String, "EXC_BAD_ACCESS (code 0), SIGSEGV")
    XCTAssertEqual(record["description"] as? String, "Namespace SIGNAL, Code 11")
    XCTAssertEqual(record["time"] as? Int64, 1_791_792_169_097)
    let stack = record["stack"] as! String
    XCTAssertTrue(stack.contains("\"binaryUUID\":\"AB-12\""), "crashed thread kept")
    XCTAssertFalse(stack.contains("libsystem_kernel"), "other threads dropped")
  }

  func testObjectiveCExceptionIsACrash() {
    let record = CrashRecord.make(
      signal: 6, exceptionType: 10, exceptionCode: nil, terminationReason: nil,
      objcExceptionName: "NSInvalidArgumentException",
      objcExceptionMessage: "-[NSNull length]: unrecognized selector",
      callStackTree: Data("not json".utf8), time: Date())

    XCTAssertEqual(record["reason"] as? String, "crash")
    XCTAssertEqual(record["type"] as? String, "NSInvalidArgumentException")
    XCTAssertEqual(record["message"] as? String, "-[NSNull length]: unrecognized selector")
    XCTAssertNil(record["description"])
    XCTAssertEqual(record["stack"] as? String, "not json", "unexpected tree kept as is")
  }

  func testStoreHandsOverEachRecordOnce() {
    let store = CrashStore(file: dir.appendingPathComponent("crashes.json"))
    append(store, [["reason": "native_crash", "time": 1]])
    append(store, [["reason": "crash", "time": 2]])

    let first = take(store)
    XCTAssertEqual(first.map { $0["time"] as? Int }, [1, 2])
    XCTAssertTrue(take(store).isEmpty, "second call returns nothing")
  }

  func testStoreIsBounded() {
    let store = CrashStore(file: dir.appendingPathComponent("crashes.json"))
    append(store, (1...25).map { ["reason": "native_crash", "time": $0] })
    let kept = take(store)
    XCTAssertEqual(kept.count, CrashStore.maxRecords)
    XCTAssertEqual(kept.first?["time"] as? Int, 6, "oldest dropped")
  }

  func testChannelReturnsPendingCrashes() {
    let done = expectation(description: "result")
    OtelFlutterNativePlugin().handle(
      FlutterMethodCall(methodName: "getPendingCrashes", arguments: nil)
    ) { result in
      XCTAssertTrue(result is [[String: Any]])
      done.fulfill()
    }
    waitForExpectations(timeout: 2)
  }
}
