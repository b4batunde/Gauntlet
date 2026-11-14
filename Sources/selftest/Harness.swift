import Foundation

/// Minimal test harness: Swift's XCTest / Testing macros need full Xcode,
/// and this project is meant to be verifiable with just the command-line tools.
enum Harness {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var checks = 0
    nonisolated(unsafe) static var current = ""
    nonisolated(unsafe) static var failedTests: [String] = []
    nonisolated(unsafe) static var testCount = 0
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
            file: StaticString = #fileID, line: UInt = #line) {
    Harness.checks += 1
    let ok = (try? condition()) ?? false
    if !ok {
        Harness.failures += 1
        if Harness.failedTests.last != Harness.current { Harness.failedTests.append(Harness.current) }
        let note = message()
        print("    FAIL \(file):\(line)\(note.isEmpty ? "" : " — " + note)")
    }
}

func expectThrows(_ body: () throws -> Void, file: StaticString = #fileID, line: UInt = #line) {
    Harness.checks += 1
    do {
        try body()
        Harness.failures += 1
        if Harness.failedTests.last != Harness.current { Harness.failedTests.append(Harness.current) }
        print("    FAIL \(file):\(line) — expected an error")
    } catch {}
}

func test(_ name: String, _ body: () throws -> Void) {
    Harness.current = name
    Harness.testCount += 1
    let before = Harness.failures
    do { try body() } catch {
        Harness.failures += 1
        Harness.failedTests.append(name)
        print("    FAIL threw \(error)")
    }
    print("  \(Harness.failures == before ? "ok  " : "FAIL") \(name)")
}

func suite(_ name: String, _ body: () -> Void) {
    print("\n\(name)")
    body()
}

func finish() -> Never {
    print("\n\(Harness.testCount) tests, \(Harness.checks) checks, \(Harness.failures) failures")
    if !Harness.failedTests.isEmpty { print("failed: " + Harness.failedTests.joined(separator: ", ")) }
    exit(Harness.failures == 0 ? 0 : 1)
}
