import Foundation
import Testing
@testable import Frostlake

/// When the connection's autocommit mode changes around `begin()`, `commit()` and `rollback()`,
/// over a stand-in engine: every request a scenario makes is one it scripted, and every one it
/// sent is on record.
@Suite struct TransactionModeTests {

    private static let scope: [String?] = ["USE DATABASE APP", "USE SCHEMA PUBLIC"]

    /// A one-row DML count, as an INSERT answers.
    private static let inserted =
        #"{"columns":[{"dataType":"NUMBER","name":"number of rows inserted","nullable":false,"#
        + #""precision":38,"scale":0}],"rowCount":1,"rows":[[1]],"updateCount":1}"#

    /// Runs `body` against a fresh stand-in, and fails on anything it did not script.
    private func withServer(_ body: (ScriptedServer) async throws -> Void) async throws {
        let server = try ScriptedServer()
        defer { server.stop() }
        try await body(server)
        #expect(server.unscripted.isEmpty, "unscripted requests: \(server.unscripted)")
    }

    /// A connection that has run one statement on an engine that reports newSession.
    private func opened(_ server: ScriptedServer) async throws -> FrostlakeConnection {
        server.reply(answer("s1", started: true, [statusSet("ok")]))
        server.reply(answer("s1", [statusSet("ok")]))
        server.reply(answer("s1", [numberSet("N", 1)]))
        let conn = try await Frostlake.connect(server.dsn("/APP?schema=PUBLIC"))
        _ = try await conn.execute("SELECT 1 AS N")
        return conn
    }

    enum BeginFailure: String, CaseIterable, Sendable {
        case refused, unreadableAnswer, closedSocket
    }

    /// A BEGIN that failed opened nothing, so the statements after it must still go out with
    /// autocommit on: sent with it off, they would run in a transaction nobody commits, rolled back
    /// unseen when the session ends.
    @Test(arguments: BeginFailure.allCases)
    func aFailedBeginLeavesAutocommitOn(_ failure: BeginFailure) async throws {
        try await withServer { server in
            let conn = try await opened(server)
            switch failure {
            case .refused:
                server.reply(refused("s1", "SQL compilation error:\nsyntax error"))
            case .unreadableAnswer:
                server.reply("<html>Bad Gateway</html>", status: 502)
            case .closedSocket:
                server.drop()
            }
            await #expect(throws: FrostlakeError.self) {
                try await conn.begin()
            }
            #expect(await conn.autoCommit)
            server.reply(answer("s1", [Self.inserted]))
            _ = try await conn.execute("INSERT INTO t VALUES (1)")
            let executes = server.executes
            #expect(executes.last?.sql == "INSERT INTO t VALUES (1)")
            #expect(executes.last?.autoCommit == true)
            // BEGIN itself still went out with autocommit off, the mode the transaction runs in.
            #expect(executes.first { $0.sql == "BEGIN" }?.autoCommit == false)
            server.reply(released)
            await conn.close()
        }
    }

    @Test func aBeginWhoseSessionCannotBeReplacedLeavesAutocommitOn() async throws {
        try await withServer { server in
            let conn = try await opened(server)
            server.reply(sessionGone("s1"), status: 404)
            server.reply(answer("s2", started: true, [statusSet("ok")]))
            server.reply(answer("s2", [statusSet("ok")]))
            server.reply(sessionGone("s2"), status: 404)
            await #expect(throws: FrostlakeError.self) {
                try await conn.begin()
            }
            #expect(await conn.autoCommit)
            // The next statement starts a fresh session on the scope, with autocommit on.
            server.reply(answer("s3", started: true, [statusSet("ok")]))
            server.reply(answer("s3", [statusSet("ok")]))
            server.reply(answer("s3", [Self.inserted]))
            _ = try await conn.execute("INSERT INTO t VALUES (1)")
            #expect(server.statements.suffix(3) == Self.scope + ["INSERT INTO t VALUES (1)"])
            #expect(server.executes.last?.autoCommit == true)
            server.reply(released)
            await conn.close()
        }
    }

    @Test func aBeginOnAClosedConnectionChangesNothing() async throws {
        try await withServer { server in
            let conn = try await opened(server)
            server.reply(released)
            await conn.close()
            await #expect(throws: FrostlakeError.connectionClosed) {
                try await conn.begin()
            }
            #expect(await conn.autoCommit)
        }
    }

    @Test func aSucceededBeginTurnsAutocommitOffUntilTheTransactionEnds() async throws {
        try await withServer { server in
            let conn = try await opened(server)
            server.reply(answer("s1", [statusSet("ok")]))
            try await conn.begin()
            #expect(await !conn.autoCommit)
            server.reply(answer("s1", [Self.inserted]))
            _ = try await conn.execute("INSERT INTO t VALUES (1)")
            #expect(server.executes.last?.autoCommit == false)
            server.reply(answer("s1", [statusSet("ok")]))
            try await conn.commit()
            #expect(await conn.autoCommit)
            server.reply(answer("s1", [statusSet("ok")]))
            try await conn.begin()
            server.reply(answer("s1", [statusSet("ok")]))
            try await conn.rollback()
            #expect(await conn.autoCommit)
            server.reply(answer("s1", [numberSet("N", 2)]))
            _ = try await conn.execute("SELECT 2 AS N")
            #expect(server.executes.last?.autoCommit == true)
            // COMMIT and ROLLBACK went out in the transaction's own mode.
            #expect(server.executes.filter { $0.sql == "COMMIT" || $0.sql == "ROLLBACK" }
                .allSatisfy { $0.autoCommit == false })
            server.reply(released)
            await conn.close()
        }
    }
}
