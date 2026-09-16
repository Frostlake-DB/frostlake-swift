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

/// Where integration tests find an engine: FROSTLAKE_URL points at a running
/// server ("frostlake://localhost:18082"); otherwise FROSTLAKE_CLASSPATH makes
/// the suite spawn a private DatabaseHttpServer on a scratch port (killed at
/// process exit). With neither set, the integration suite is skipped.
enum TestEnvironment {
    static var available: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["FROSTLAKE_URL"] != nil || env["FROSTLAKE_CLASSPATH"] != nil
    }

    /// Unique-per-run suffix so tests can rerun against a long-lived server.
    static let runTag = String(UInt64(Date().timeIntervalSince1970 * 1000) % 1_000_000_000, radix: 36)
        .uppercased()
}

/// The spawned engine's pid, reachable from the C atexit handler.
nonisolated(unsafe) var spawnedEnginePid: Int32 = 0

actor TestServer {
    static let shared = TestServer()

    private var cachedHostPort: String?
    private var cachedCountsStatements: Bool?
    private var cachedReportsColumnLength: Bool?
    private var cachedReportsUpdateCount: Bool?

    func hostPort() async throws -> String {
        if let cachedHostPort { return cachedHostPort }
        let env = ProcessInfo.processInfo.environment
        if let url = env["FROSTLAKE_URL"] {
            let cfg = try FrostlakeConfig(dsn: url)
            let hostPort = String(cfg.baseUrl.dropFirst("http://".count))
            cachedHostPort = hostPort
            return hostPort
        }
        guard let classpath = env["FROSTLAKE_CLASSPATH"] else {
            throw FrostlakeError.transport("set FROSTLAKE_URL or FROSTLAKE_CLASSPATH to run integration tests")
        }
        let port = Int.random(in: 20_000..<40_000)
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("frostlake-swift-itest-\(port).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["java", "-cp", classpath, "dev.frostlake.http.DatabaseHttpServer", "\(port)"]
        process.standardOutput = handle
        process.standardError = handle
        // Run the engine from the temp dir so its own db-engine.log lands
        // there rather than in this repository.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        try process.run()
        spawnedEnginePid = process.processIdentifier
        atexit {
            if spawnedEnginePid > 0 {
                kill(spawnedEnginePid, SIGTERM)
            }
        }
        let health = URL(string: "http://localhost:\(port)/api/health")!
        for _ in 0..<120 {
            if !process.isRunning {
                throw FrostlakeError.transport("engine exited during startup; log: \(log.path)")
            }
            do {
                let (_, response) = try await URLSession.shared.data(for: URLRequest(url: health))
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    let hostPort = "localhost:\(port)"
                    cachedHostPort = hostPort
                    return hostPort
                }
            } catch {
                // Not up yet; keep polling.
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw FrostlakeError.transport("engine did not become healthy in 60s; log: \(log.path)")
    }

    /// Whether the engine refuses a request whose statement count nobody declared. Engines
    /// before 0.1.0 run any pack they are sent, so there is no refusal to observe on one of
    /// those and the tests that look for it report as skipped rather than passed.
    func countsStatements() async -> Bool {
        if let cachedCountsStatements { return cachedCountsStatements }
        var counts = false
        do {
            let conn = try await Frostlake.connect(try await dsn())
            do {
                _ = try await conn.execute("SELECT 1 AS A; SELECT 2 AS B")
            } catch {
                counts = true
            }
            await conn.close()
        } catch {
            counts = false
        }
        cachedCountsStatements = counts
        return counts
    }

    /// Whether the engine sends a column's declared length. Engines before 0.1.0 send no length
    /// at all, so a driver reports the width as unknown and there is nothing to check.
    func reportsColumnLength() async -> Bool {
        if let cachedReportsColumnLength { return cachedReportsColumnLength }
        var reports = false
        do {
            let conn = try await Frostlake.connect(try await dsn())
            let result = try await conn.execute("SELECT CAST('x' AS VARCHAR(9)) AS S")
            reports = result.columns.first?.length != nil
            await conn.close()
        } catch {
            reports = false
        }
        cachedReportsColumnLength = reports
        return reports
    }

    /// Whether the engine reports each result set's update count. Engines before 0.1.0 send none,
    /// so the probe reads the wire directly: the driver's own shaping is what the tests check.
    func reportsUpdateCount() async -> Bool {
        if let cachedReportsUpdateCount { return cachedReportsUpdateCount }
        var reports = false
        do {
            var request = URLRequest(url: URL(string: "http://\(try await hostPort())/api/execute")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = JSONText.requestBody(sql: "SELECT 1", sessionId: nil, autoCommit: true)
            let (data, _) = try await URLSession.shared.data(for: request)
            reports = WireEnvelope(root: try JSONParser.parse(data)).resultSets.first?.updateCount != nil
        } catch {
            reports = false
        }
        cachedReportsUpdateCount = reports
        return reports
    }

    func dsn(database: String? = nil, schema: String? = nil) async throws -> String {
        var out = "frostlake://\(try await hostPort())/"
        if let database { out += database }
        if let schema { out += "?schema=\(schema)" }
        return out
    }
}
