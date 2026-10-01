// Runs the engine-owned, language-neutral JSON test suites through THIS driver.
//
// The definitions live in the frostlake repo (engine/src/test/resources/testkit/suites/*.json,
// spec in SCHEMA.md beside them); every statement travels this driver -> HTTP ->
// DatabaseHttpServer. The engine owns the definitions and this file is only the Swift runner — a
// port of the Java reference's JsonSuiteTest / Compare / HttpBackend — so suites added on the
// engine side are picked up here with no driver change.
//
//   export FL_CORPUS=/path/to/frostlake/engine/src/test/resources/testkit
//   FROSTLAKE_CLASSPATH="$(scripts/engine-classpath.sh 0.1.0)" swift test --filter TestkitSuitesTests
//   FROSTLAKE_URL=frostlake://localhost:18082 swift test --filter TestkitSuitesTests
//
// FL_CORPUS names the testkit directory whose suites/*.json replay (a relative path resolves
// against the working directory); without it the test is skipped, and one holding no suites fails
// it. The first command boots a private engine (its own user.home and working directory, so stage
// files and logs stay out of shared places); the second attaches to a running one.
// TESTKIT_SUITES=a,b keeps only the suites whose name contains a listed word, as in the reference.
// With no engine named the run skips, so a checkout without one is never falsely green. The
// per-test report lands in FROSTLAKE_TESTKIT_REPORT, or testkit-swift.tsv in the temp directory.
//
// Semantics (mirroring SCHEMA.md and the reference):
//   - a test's skip clause applies when it names `swift`, or `http` — the transport this speaks.
//   - per-test isolation: the reference's reset sequence, then the steps on ONE connection, which
//     keeps USE, variables and transactions on a single session.
//   - capabilities: SESSION, COLUMN_NAMES, UPDATE_COUNT. No ERROR_CODE — the protocol carries a
//     message only — so an expected error's code or sqlState counts as a missing API rather than
//     as a failure.
//   - values compare after the reference's normalization: NULL and booleans folded, anything
//     numeric rounded to 10 significant digits (HALF_UP) and printed plain, everything else
//     trimmed text.

import Foundation
import Testing
@testable import Frostlake
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@Suite struct TestkitSuitesTests {

    // An FL_CORPUS without suites is an error rather than a reason to skip, so the engine condition
    // lets it through for the test to fail on.
    @Test(.enabled(if: TestkitSetup.corpus != nil,
                   "set FL_CORPUS to frostlake's engine/src/test/resources/testkit to replay the testkit corpus"),
          .enabled(if: TestkitSetup.engineNamed || TestkitSetup.suitesDirectory == nil,
                   "set FROSTLAKE_URL, or FROSTLAKE_CLASSPATH to boot an engine"))
    func suitesPassThroughTheDriver() async throws {
        let directory = try #require(
            TestkitSetup.suitesDirectory,
            "FL_CORPUS=\(TestkitSetup.corpus ?? ""): no *.json suites in \(TestkitSetup.suitesPath)")
        let engine = try await TestkitEngine.start()
        defer { engine.stop() }
        let connection = try await Frostlake.connect(engine.dsn)
        let report = TestkitSetup.reportPath
        let summary = try await TestkitRunner(connection: connection)
            .run(directory: directory, wanted: TestkitSetup.wantedSuites, reportPath: report)
        print("""
            testkit [swift]: \(summary.passed) passed, \(summary.failed) failed, \(summary.skipped) skipped, \
            \(summary.missingApi) check(s) needing an API the HTTP transport lacks — \(summary.suites) suite \
            files in \(String(format: "%.1f", summary.seconds)) s, report \(report)
            """)
        for line in summary.firstFailures {
            print("  \(line)")
        }
        #expect(summary.failed == 0, "testkit cases failed; see \(report)")
    }

    @Test func normalizationMatchesTheReference() {
        // Generated from the reference's own Compare.norm and BigDecimal.toPlainString, run on each
        // input: (input, normalized, plain number or nil when BigDecimal refuses the text).
        let table: [(String, String, String?)] = [
            ("2", "2", "2"),
            ("2.000000", "2", "2.000000"),
            ("3.500000", "3.5", "3.500000"),
            (" 42 ", "42", nil),
            ("-0", "0", "0"),
            ("0.000", "0", "0.000"),
            ("1e+21", "1000000000000000000000", "1000000000000000000000"),
            ("2.5e-05", "0.000025", "0.000025"),
            ("0.30000000000000004", "0.3", "0.30000000000000004"),
            ("12345678905", "12345678910", "12345678905"),
            ("9999999999.5", "10000000000", "9999999999.5"),
            ("-12345678901234567890123456789", "-12345678900000000000000000000", "-12345678901234567890123456789"),
            ("1.", "1", "1"),
            (".5", "0.5", "0.5"),
            ("+7", "7", "7"),
            ("1e", "1e", nil),
            ("0x10", "0x10", nil),
            ("NaN", "NaN", nil),
            ("true", "TRUE", nil),
            ("False", "FALSE", nil),
            ("null", "NULL", nil),
            ("", "NULL", nil),
            ("abc", "abc", nil),
            ("1.0E10", "10000000000", "10000000000"),
            ("1.0E-5", "0.00001", "0.000010"),
            ("-1.5E-7", "-0.00000015", "-0.00000015"),
            ("123456789012345678901234567890.123456789", "123456789000000000000000000000", "123456789012345678901234567890.123456789"),
            ("0.00000000012345678915", "0.0000000001234567892", "0.00000000012345678915"),
            ("0.99999999995", "1", "0.99999999995"),
            ("-9999999999.5", "-10000000000", "-9999999999.5"),
            ("1E+3", "1000", "1000"),
            ("1e0", "1", "1"),
            ("+.5", "0.5", "0.5"),
            (".", ".", nil),
            ("-", "-", nil),
            ("+", "+", nil),
            ("1e+", "1e+", nil),
            ("1e-", "1e-", nil),
            ("1.2.3", "1.2.3", nil),
            ("1e5.5", "1e5.5", nil),
            ("--1", "--1", nil),
            ("Infinity", "Infinity", nil),
            ("-Infinity", "-Infinity", nil),
            ("inf", "inf", nil),
            ("nan", "nan", nil),
            ("5e-30", "0.000000000000000000000000000005", "0.000000000000000000000000000005"),
            ("1.7976931348623157E30", "1797693135000000000000000000000", "1797693134862315700000000000000"),
            ("\t7\n", "7", nil),
            ("TRUE ", "TRUE", nil),
            ("NULL", "NULL", nil),
            ("nuLL", "NULL", nil),
            ("00012", "12", "12"),
            ("-0.0", "0", "0.0"),
            ("0e10", "0", "0"),
            ("12345678901", "12345678900", "12345678901"),
            ("1234567890.5", "1234567891", "1234567890.5"),
            ("1234567890.4999", "1234567890", "1234567890.4999"),
            ("100", "100", "100"),
            ("1.000000000000000000001", "1", "1.000000000000000000001"),
            ("6.02214076e23", "602214076000000000000000", "602214076000000000000000"),
            ("DEADBEEF", "DEADBEEF", nil),
            ("0123", "123", "123"),
            ("-00.00100", "-0.001", "-0.00100"),
            ("1 2", "1 2", nil),
            ("12e-3", "0.012", "0.012"),
            ("1234.5678e2", "123456.78", "123456.78"),
        ]
        for (raw, normalized, plain) in table {
            #expect(TestkitCompare.norm(raw) == normalized, "norm(\(raw.debugDescription))")
            #expect(DecimalText(raw)?.plain == plain, "plain(\(raw.debugDescription))")
        }
        #expect(TestkitCompare.norm(nil) == "NULL")
    }
}

// ── where the engine and the suites are ──────────────────────────────────────────────────────────

private enum TestkitSetup {
    /// The testkit directory FL_CORPUS names — frostlake's engine/src/test/resources/testkit — or
    /// nil when it names none.
    static var corpus: String? {
        guard let value = ProcessInfo.processInfo.environment["FL_CORPUS"], !value.isEmpty else { return nil }
        return value
    }

    static var engineNamed: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["FROSTLAKE_URL"] != nil || env["FROSTLAKE_CLASSPATH"] != nil
    }

    /// FL_CORPUS's suites/ directory; a relative FL_CORPUS resolves against the working directory.
    static var suitesPath: String {
        URL(fileURLWithPath: corpus ?? "").appendingPathComponent("suites").path
    }

    /// The suites directory, or nil when it holds no suite file.
    static var suitesDirectory: String? {
        guard corpus != nil,
              let names = try? FileManager.default.contentsOfDirectory(atPath: suitesPath),
              names.contains(where: { $0.hasSuffix(".json") }) else {
            return nil
        }
        return suitesPath
    }

    static var wantedSuites: [String] {
        guard let listed = ProcessInfo.processInfo.environment["TESTKIT_SUITES"] else { return [] }
        var words: [String] = []
        for word in listed.split(separator: ",") {
            let trimmed = word.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                words.append(trimmed.lowercased())
            }
        }
        return words
    }

    static var reportPath: String {
        if let explicit = ProcessInfo.processInfo.environment["FROSTLAKE_TESTKIT_REPORT"] {
            return explicit
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("testkit-swift.tsv").path
    }
}

/// The booted engine's pid, reachable from the C atexit handler should the run die before stopping it.
nonisolated(unsafe) private var testkitEnginePid: Int32 = 0

private final class TestkitEngine: @unchecked Sendable {
    let dsn: String
    private let process: Process?
    private let home: URL?

    private init(dsn: String, process: Process?, home: URL?) {
        self.dsn = dsn
        self.process = process
        self.home = home
    }

    static func start() async throws -> TestkitEngine {
        let env = ProcessInfo.processInfo.environment
        if let url = env["FROSTLAKE_URL"] {
            return TestkitEngine(dsn: url, process: nil, home: nil)
        }
        guard let classpath = env["FROSTLAKE_CLASSPATH"] else {
            throw FrostlakeError.transport("set FROSTLAKE_URL, or FROSTLAKE_CLASSPATH to boot an engine")
        }
        guard let port = freeLoopbackPort() else {
            throw FrostlakeError.transport("cannot find a free port for the engine")
        }
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("frostlake-swift-testkit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let log = home.appendingPathComponent("engine.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let arguments = ["-Duser.home=\(home.path)", "-cp", classpath, "dev.frostlake.http.DatabaseHttpServer", "\(port)"]
        let process = Process()
        if let javaHome = env["JAVA_HOME"] {
            process.executableURL = URL(fileURLWithPath: javaHome).appendingPathComponent("bin/java")
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["java"] + arguments
        }
        // The engine logs to stderr; a pipe nobody drains would stall it mid-run.
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        process.currentDirectoryURL = home
        try process.run()
        testkitEnginePid = process.processIdentifier
        atexit {
            if testkitEnginePid > 0 {
                kill(testkitEnginePid, SIGTERM)
            }
        }
        let engine = TestkitEngine(dsn: "frostlake://127.0.0.1:\(port)", process: process, home: home)
        let health = URL(string: "http://127.0.0.1:\(port)/api/health")!
        for _ in 0..<300 {
            if !process.isRunning {
                throw FrostlakeError.transport("the engine exited during startup; log: \(log.path)")
            }
            if let reply = try? await URLSession.shared.data(for: URLRequest(url: health)),
               (reply.1 as? HTTPURLResponse)?.statusCode == 200 {
                return engine
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        engine.stop(keepingLog: true)
        throw FrostlakeError.transport("the engine did not become healthy in 60 s; log: \(log.path)")
    }

    func stop(keepingLog: Bool = false) {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        testkitEnginePid = 0
        if !keepingLog, let home {
            try? FileManager.default.removeItem(at: home)
        }
    }
}

private func freeLoopbackPort() -> Int? {
    #if canImport(Glibc)
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = in_addr_t(UInt32(0x7F00_0001).bigEndian)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
    }
    guard bound == 0 else { return nil }
    let named = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard named == 0 else { return nil }
    return Int(UInt16(bigEndian: address.sin_port))
}

// ── the run ──────────────────────────────────────────────────────────────────────────────────────

private enum TestkitStatus: String {
    case pass = "PASS"
    case fail = "FAIL"
    case error = "ERROR"
    case skip = "SKIP"
}

private struct TestkitCaseResult {
    var status: TestkitStatus
    var failedStep = 0
    var detail = ""
}

private struct TestkitSummary {
    var passed = 0
    var failed = 0
    var skipped = 0
    var missingApi = 0
    var suites = 0
    var seconds = 0.0
    var firstFailures: [String] = []
}

private struct TestkitRunner {
    /// The reference's reset, before every test: a session that takes a script, then a fresh
    /// test_db.test_schema, made current.
    static let resetContext = [
        "ALTER SESSION SET MULTI_STATEMENT_COUNT = 0",
        "CREATE OR REPLACE DATABASE test_db",
        "USE DATABASE test_db",
        "CREATE OR REPLACE SCHEMA test_schema",
        "USE SCHEMA test_schema",
    ]

    static let maxReportedFailures = 20

    let connection: FrostlakeConnection

    func run(directory: String, wanted: [String], reportPath: String) async throws -> TestkitSummary {
        let started = Date()
        var summary = TestkitSummary()
        var tsv = "suite\ttest\tstatus\tfailedStep\tdetail\tms\n"
        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        for file in files {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(file)
            let suite = try JSONParser.parse(try Data(contentsOf: url))
            let suiteName = suite.objectOrNil?["suite"]?.stringOrNil ?? String(file.dropLast(".json".count))
            guard Self.isWanted(suiteName, wanted) else { continue }
            summary.suites += 1
            for test in suite.objectOrNil?["tests"]?.arrayOrNil ?? [] {
                let name = test.objectOrNil?["name"]?.stringOrNil ?? ""
                let tick = Date()
                let outcome: TestkitCaseResult
                if let reason = Self.skipReason(test) {
                    outcome = TestkitCaseResult(status: .skip, detail: reason)
                } else {
                    outcome = await runCase(test, missingApi: &summary.missingApi)
                }
                switch outcome.status {
                case .pass:
                    summary.passed += 1
                case .skip:
                    summary.skipped += 1
                case .fail, .error:
                    summary.failed += 1
                    if summary.firstFailures.count < Self.maxReportedFailures {
                        let line = "\(suiteName) / \(name): \(outcome.status.rawValue) \(outcome.detail)"
                        summary.firstFailures.append(String(line.prefix(300)))
                    }
                }
                let ms = outcome.status == .skip ? 0 : Int(Date().timeIntervalSince(tick) * 1000)
                let step = outcome.failedStep > 0 ? String(outcome.failedStep) : ""
                tsv += "\(suiteName)\t\(name)\t\(outcome.status.rawValue)\t\(step)\t\(Self.singleLine(outcome.detail))\t\(ms)\n"
            }
        }
        try tsv.write(toFile: reportPath, atomically: true, encoding: .utf8)
        summary.seconds = Date().timeIntervalSince(started)
        return summary
    }

    private func runCase(_ test: JSONValue, missingApi: inout Int) async -> TestkitCaseResult {
        for sql in Self.resetContext {
            do {
                _ = try await connection.execute(sql)
            } catch {
                return TestkitCaseResult(status: .error, detail: "resetContext failed on '\(sql)': \(error)")
            }
        }
        let steps = test.objectOrNil?["steps"]?.arrayOrNil ?? []
        for (index, step) in steps.enumerated() {
            let fields = step.objectOrNil ?? [:]
            guard let sql = fields["sql"]?.stringOrNil else {
                return TestkitCaseResult(status: .error, failedStep: index + 1, detail: "step has no sql")
            }
            let result: TestkitExecResult
            do {
                result = TestkitExecResult(try await connection.execute(sql))
            } catch FrostlakeError.sql(let message) {
                result = TestkitExecResult(errorMessage: message)
            } catch {
                // A transport failure is an ERROR, as in the reference — never an "expected error".
                return TestkitCaseResult(status: .error, failedStep: index + 1, detail: "\(error)  [sql: \(sql)]")
            }
            let (mismatch, skippedChecks) = TestkitCompare.check(fields["expect"], result)
            if let mismatch {
                return TestkitCaseResult(status: .fail, failedStep: index + 1, detail: "\(mismatch)  [sql: \(sql)]")
            }
            missingApi += skippedChecks
        }
        return TestkitCaseResult(status: .pass)
    }

    private static func isWanted(_ suiteName: String, _ wanted: [String]) -> Bool {
        if wanted.isEmpty { return true }
        let name = suiteName.lowercased()
        for word in wanted where name.contains(word) {
            return true
        }
        return false
    }

    /// The skip clause names this runner: `swift`, or `http` — the transport it speaks.
    private static func skipReason(_ test: JSONValue) -> String? {
        guard let clause = test.objectOrNil?["skip"]?.objectOrNil else { return nil }
        for backend in clause["backends"]?.arrayOrNil ?? [] {
            guard let name = backend.stringOrNil else { continue }
            let lowered = name.lowercased()
            if lowered == "swift" || lowered == "http" {
                return clause["reason"]?.stringOrNil ?? "skipped for \(name)"
            }
        }
        return nil
    }

    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\u{1f}", with: "|")
    }
}

/// One statement's outcome in the reference's terms: the first result grid as text (a nil cell is
/// SQL NULL, a nil grid means no result set), the DML count, or the refusal.
private struct TestkitExecResult {
    var columns: [String]?
    var rows: [[String?]]?
    var updateCount: Int64 = -1
    var errorMessage: String?

    init(errorMessage: String) {
        self.errorMessage = errorMessage
    }

    init(_ result: FrostlakeResult) {
        guard let first = result.resultSets.first else { return }
        var names: [String] = []
        var semiStructured: [Bool] = []
        for column in first.columns {
            names.append(column.name)
            let type = column.dataType.uppercased()
            semiStructured.append(type == "VARIANT" || type == "OBJECT" || type == "ARRAY")
        }
        var grid: [[String?]] = []
        for row in first.rows {
            var cells: [String?] = []
            for (index, value) in row.values.enumerated() {
                cells.append(Self.text(value, semiStructured: index < semiStructured.count && semiStructured[index]))
            }
            grid.append(cells)
        }
        columns = names
        rows = grid
        updateCount = Self.updateCount(first)
        deriveUpdateCountFromGrid()
    }

    var firstCell: String? {
        guard let rows, let first = rows.first, let cell = first.first else { return nil }
        return cell
    }

    /// The driver's own DML count, -1 when it reports none.
    private static func updateCount(_ set: FrostlakeResultSet) -> Int64 {
        set.updateCount ?? -1
    }

    /// The reference's derivation when no count came through: a single row whose every column is a
    /// "number of …" count answers its first cell.
    private mutating func deriveUpdateCountFromGrid() {
        guard updateCount < 0, let columns, !columns.isEmpty, let rows, rows.count == 1 else { return }
        for column in columns where !column.lowercased().hasPrefix("number of") {
            return
        }
        guard let first = rows[0].first, let text = first,
              let count = Int64(JavaText.trim(text)) else { return }
        updateCount = count
    }

    /// A cell as the reference's HTTP backend stringifies the wire value. A semi-structured cell
    /// reaches a client as its JSON text while the suites record the value, so such a cell is
    /// decoded once: a JSON string becomes its content, anything else stays as it came.
    private static func text(_ value: FrostlakeValue, semiStructured: Bool) -> String? {
        let text: String
        switch value {
        case .null: return nil
        case .int(let v): text = String(v)
        case .decimal(let v): text = "\(v)"
        case .double(let v): text = "\(v)"
        case .bool(let v): text = v ? "true" : "false"
        case .string(let v): text = v
        case .binary: text = value.description
        }
        guard semiStructured,
              let parsed = try? JSONParser.parse(Data(text.utf8)),
              case .string(let content) = parsed else {
            return text
        }
        return content
    }
}

// ── the reference's Compare ──────────────────────────────────────────────────────────────────────

private enum TestkitCompare {
    private static let cellSeparator = "\u{1f}"

    /// One step's expect block against the driver's outcome: the mismatch, if any, and how many
    /// checks needed an API this transport lacks.
    static func check(_ expect: JSONValue?, _ result: TestkitExecResult) -> (mismatch: String?, missingApi: Int) {
        let fields = expect?.objectOrNil
        if let error = fields?["error"]?.objectOrNil {
            return checkRefusal(error, result)
        }
        if let message = result.errorMessage {
            return ("unexpected error: \(message)", 0)
        }
        guard let fields else { return (nil, 0) }
        if let want = fields["value"] {
            let expected = JavaText.string(want)
            let actual = result.firstCell
            if !JavaText.same(norm(expected), norm(actual)) {
                return ("value [\(actual ?? "null")] != expected [\(expected)]", 0)
            }
        }
        if let wantRows = fields["rows"]?.arrayOrNil {
            let ordered = fields["ordered"]?.boolOrNil == true
            if let diff = gridDiff(expectedGrid(wantRows), result.rows ?? [], ordered: ordered) {
                return (diff, 0)
            }
        }
        if let wantCount = fields["rowCount"].flatMap(JavaText.int) {
            let got = result.rows?.count ?? 0
            if got != wantCount {
                return ("rowCount \(got) != expected \(wantCount)", 0)
            }
        }
        if let wantColumns = fields["columns"]?.arrayOrNil,
           let mismatch = columnMismatch(wantColumns, result.columns ?? []) {
            return (mismatch, 0)
        }
        if let wantUpdateCount = fields["updateCount"].flatMap(JavaText.int),
           result.updateCount != Int64(wantUpdateCount) {
            return ("updateCount \(result.updateCount) != expected \(wantUpdateCount)", 0)
        }
        return (nil, 0)
    }

    /// The statement is EXPECTED to fail: check it did, with the named message. A code or sqlState
    /// cannot be checked over this transport, which reports a message only.
    private static func checkRefusal(_ error: [String: JSONValue], _ result: TestkitExecResult) -> (mismatch: String?, missingApi: Int) {
        guard let message = result.errorMessage else {
            return ("expected an error, statement succeeded", 0)
        }
        if let want = error["messageContains"].flatMap(JavaText.getStr),
           !message.lowercased().contains(want.lowercased()) {
            return ("error message [\(message)] does not contain [\(want)]", 0)
        }
        let code = error["code"].flatMap(JavaText.getStr)
        let state = error["sqlState"].flatMap(JavaText.getStr)
        return (nil, code == nil && state == nil ? 0 : 1)
    }

    private static func expectedGrid(_ rows: [JSONValue]) -> [[String?]] {
        var grid: [[String?]] = []
        for row in rows {
            var cells: [String?] = []
            for cell in row.arrayOrNil ?? [] {
                cells.append(cell == .null ? nil : JavaText.string(cell))
            }
            grid.append(cells)
        }
        return grid
    }

    private static func columnMismatch(_ expected: [JSONValue], _ got: [String]) -> String? {
        if got.count != expected.count {
            return "column count \(got.count) != expected \(expected.count) \(JavaText.list(got))"
        }
        for (index, want) in expected.enumerated() {
            let wantText = JavaText.string(want)
            if wantText.lowercased() != got[index].lowercased() {
                return "column[\(index)] [\(got[index])] != expected [\(wantText)]"
            }
        }
        return nil
    }

    private static func gridDiff(_ want: [[String?]], _ got: [[String?]], ordered: Bool) -> String? {
        var expected = canon(want)
        var actual = canon(got)
        if !ordered {
            expected.sort(by: JavaText.precedes)
            actual.sort(by: JavaText.precedes)
        }
        if expected.count == actual.count && zip(expected, actual).allSatisfy(JavaText.same) {
            return nil
        }
        return "rows differ: expected \(JavaText.list(expected)) got \(JavaText.list(actual))"
    }

    private static func canon(_ grid: [[String?]]) -> [String] {
        var lines: [String] = []
        for row in grid {
            var line = ""
            for cell in row {
                line += norm(cell) + cellSeparator
            }
            lines.append(line)
        }
        return lines
    }

    /// The shared value normalization, applied to both sides before they compare: NULL and the
    /// empty string alike, booleans case-insensitive, anything BigDecimal reads rounded to 10
    /// significant digits and printed plain, everything else trimmed text.
    static func norm(_ raw: String?) -> String {
        guard let raw else { return "NULL" }
        let value = JavaText.trim(raw)
        if value.isEmpty || JavaText.equalsIgnoringASCIICase(value, "null") {
            return "NULL"
        }
        if JavaText.equalsIgnoringASCIICase(value, "true") {
            return "TRUE"
        }
        if JavaText.equalsIgnoringASCIICase(value, "false") {
            return "FALSE"
        }
        return DecimalText(value)?.normalized ?? value
    }
}

/// A number as java.math.BigDecimal reads its text: a sign, the unscaled digits and a scale, so the
/// value is digits × 10^-scale.
struct DecimalText {
    private(set) var negative = false
    /// The magnitude, most significant first, without leading zeros; empty for zero.
    private(set) var digits: [UInt8] = []
    private(set) var scale = 0

    init?(_ text: String) {
        let bytes = Array(text.utf8)
        var i = 0
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") {
            negative = bytes[i] == UInt8(ascii: "-")
            i += 1
        }
        var all: [UInt8] = []
        var fractionDigits = 0
        var seenPoint = false
        while i < bytes.count {
            let c = bytes[i]
            if c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") {
                all.append(c - UInt8(ascii: "0"))
                if seenPoint { fractionDigits += 1 }
            } else if c == UInt8(ascii: ".") && !seenPoint {
                seenPoint = true
            } else {
                break
            }
            i += 1
        }
        guard !all.isEmpty else { return nil }
        var exponent = 0
        if i < bytes.count {
            guard bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") else { return nil }
            i += 1
            var exponentNegative = false
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") {
                exponentNegative = bytes[i] == UInt8(ascii: "-")
                i += 1
            }
            guard i < bytes.count else { return nil }
            while i < bytes.count {
                let c = bytes[i]
                guard c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") else { return nil }
                exponent = exponent * 10 + Int(c - UInt8(ascii: "0"))
                // The reference overflows on such an exponent rather than answering; as text it
                // still compares.
                guard exponent <= 100_000 else { return nil }
                i += 1
            }
            if exponentNegative { exponent = -exponent }
        }
        if let first = all.firstIndex(where: { $0 != 0 }) {
            digits = Array(all[first...])
        }
        scale = fractionDigits - exponent
    }

    /// BigDecimal.toPlainString.
    var plain: String {
        guard !digits.isEmpty else {
            return scale > 0 ? "0." + String(repeating: "0", count: scale) : "0"
        }
        let text = String(decoding: digits.map { $0 + UInt8(ascii: "0") }, as: UTF8.self)
        let sign = negative ? "-" : ""
        if scale == 0 {
            return sign + text
        }
        if scale < 0 {
            return sign + text + String(repeating: "0", count: -scale)
        }
        let point = digits.count - scale
        if point > 0 {
            return sign + String(text.prefix(point)) + "." + String(text.dropFirst(point))
        }
        return sign + "0." + String(repeating: "0", count: -point) + text
    }

    /// Compare.norm's numeric branch: zero, or round(MathContext(10)) — HALF_UP — then
    /// stripTrailingZeros().toPlainString().
    var normalized: String {
        guard !digits.isEmpty else { return "0" }
        var rounded = self
        if rounded.digits.count > 10 {
            let roundUp = rounded.digits[10] >= 5
            rounded.scale -= rounded.digits.count - 10
            rounded.digits.removeLast(rounded.digits.count - 10)
            if roundUp {
                var k = 9
                while k >= 0 && rounded.digits[k] == 9 {
                    rounded.digits[k] = 0
                    k -= 1
                }
                if k >= 0 {
                    rounded.digits[k] += 1
                } else {
                    rounded.digits.insert(1, at: 0)
                    rounded.digits.removeLast()
                    rounded.scale -= 1
                }
            }
        }
        while rounded.digits.count > 1 && rounded.digits.last == 0 {
            rounded.digits.removeLast()
            rounded.scale -= 1
        }
        return rounded.plain
    }
}

/// Java's string semantics where the reference relies on them: String.valueOf, trim, and exact
/// UTF-16 comparison.
private enum JavaText {
    /// String.valueOf of a parsed suite value, a number printed as BigDecimal.toPlainString.
    static func string(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let raw): return DecimalText(raw)?.plain ?? raw
        case .string(let s): return s
        case .array(let items): return list(items.map(string))
        case .object(let fields):
            var members: [String] = []
            for key in fields.keys.sorted() {
                members.append("\(key)=\(string(fields[key]!))")
            }
            return "{" + members.joined(separator: ", ") + "}"
        }
    }

    /// Json.getStr: absent for a JSON null.
    static func getStr(_ value: JSONValue) -> String? {
        value == .null ? nil : string(value)
    }

    /// Json.getInt: a number's intValue, nothing for any other kind.
    static func int(_ value: JSONValue) -> Int? {
        guard case .number(let raw) = value else { return nil }
        if let exact = Int(raw) { return exact }
        guard let plain = DecimalText(raw)?.plain else { return nil }
        return Int(plain.split(separator: ".").first ?? "")
    }

    static func list(_ items: [String]) -> String {
        "[" + items.joined(separator: ", ") + "]"
    }

    /// String.trim: every leading and trailing char at or below U+0020.
    static func trim(_ text: String) -> String {
        let units = Array(text.utf16)
        var start = 0
        var end = units.count
        while start < end && units[start] <= 0x20 { start += 1 }
        while end > start && units[end - 1] <= 0x20 { end -= 1 }
        if start == 0 && end == units.count { return text }
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    static func equalsIgnoringASCIICase(_ text: String, _ word: String) -> Bool {
        let a = Array(text.utf16)
        let b = Array(word.utf16)
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            let lx = x >= 0x41 && x <= 0x5A ? x + 0x20 : x
            let ly = y >= 0x41 && y <= 0x5A ? y + 0x20 : y
            if lx != ly { return false }
        }
        return true
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.utf16.elementsEqual(b.utf16)
    }

    static func precedes(_ a: String, _ b: String) -> Bool {
        a.utf16.lexicographicallyPrecedes(b.utf16)
    }
}
