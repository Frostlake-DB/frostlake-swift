import Foundation
import Testing
@testable import Frostlake

/// How a connection keeps its idea of the engine session in step with the
/// engine's, over a stand-in engine: every request a scenario makes is one it
/// scripted, and every one it sent is on record.
@Suite struct SessionLifetimeTests {

    private static let scope: [String?] = ["USE DATABASE APP", "USE SCHEMA PUBLIC"]

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

    /// The message of the `.sessionLost` error `body` throws; an issue is
    /// recorded when it throws anything else, or nothing.
    private func sessionLost(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            Issue.record("expected FrostlakeError.sessionLost, and nothing was thrown")
        } catch FrostlakeError.sessionLost(let message) {
            return message
        } catch {
            Issue.record("expected FrostlakeError.sessionLost, got \(error)")
        }
        return nil
    }

    @Test func anOlderEngineIsNeverSentRequireSessionNorADelete() async throws {
        try await withServer { server in
            server.reply(legacyAnswer("old1", [statusSet("ok")]))
            server.reply(legacyAnswer("old1", [statusSet("ok")]))
            server.reply(legacyAnswer("old1", [numberSet("N", 1)]))
            let conn = try await Frostlake.connect(server.dsn("/APP?schema=PUBLIC"))
            let result = try await conn.execute("SELECT 1 AS N")
            #expect(result.rows.first?["N"] == .int(1))
            await conn.close()
            #expect(server.statements == Self.scope + ["SELECT 1 AS N"])
            // The session id travels once it is known, the flag never does: an older
            // engine's parser need not accept a field it does not know.
            #expect(server.executes.dropFirst().allSatisfy { $0.sessionId == "old1" })
            #expect(server.sent.allSatisfy { !$0.hasRequireSession })
            #expect(!server.sent.contains { $0.method == "DELETE" })
        }
    }

    @Test func requireSessionTravelsOnlyOnceTheEngineIsKnownToReadIt() async throws {
        try await withServer { server in
            let conn = try await opened(server)
            let executes = server.executes
            try #require(executes.count == 3)
            // The first request names no session, so there is nothing to require yet;
            // its answer's newSession is what says the engine understands the flag.
            #expect(executes[0].sessionId == nil)
            #expect(!executes[0].hasRequireSession)
            for request in executes.dropFirst() {
                #expect(request.sessionId == "s1")
                #expect(request.requireSession == true)
            }
            server.reply(released)
            await conn.close()
        }
    }

    @Test func aLostSessionIsReplacedOnTheScopeAndTheStatementSentOnceMore() async throws {
        try await withServer { server in
            let conn = try await opened(server)
            server.reply(sessionGone("s1"), status: 404)
            server.reply(answer("s2", started: true, [statusSet("ok")]))
            server.reply(answer("s2", [statusSet("ok")]))
            server.reply(answer("s2", [numberSet("N", 2)]))
            let result = try await conn.execute("SELECT 2 AS N")
            #expect(result.rows.first?["N"] == .int(2))
            #expect(server.statements
                == Self.scope + ["SELECT 1 AS N", "SELECT 2 AS N"] + Self.scope + ["SELECT 2 AS N"])
            let executes = server.executes
            try #require(executes.count == 7)
            // The replacement starts without an id, as a first request does.
            #expect(executes[4].sessionId == nil)
            #expect(!executes[4].hasRequireSession)
            #expect(executes[6].sessionId == "s2")
            #expect(executes[6].requireSession == true)
            #expect(await conn.sessionId == "s2")
            #expect(server.pending == 0)
            server.reply(released)
            await conn.close()
            #expect(server.sent.last?.path == "/api/sessions/s2")
        }
    }

    @Test func aSecondRefusalIsThrownAndTheConnectionStartsOverAfterIt() async throws {
        try await withServer { server in
            let conn = try await opened(server)
            server.reply(sessionGone("s1"), status: 404)
            server.reply(answer("s2", started: true, [statusSet("ok")]))
            server.reply(answer("s2", [statusSet("ok")]))
            server.reply(sessionGone("s2"), status: 404)
            let message = await sessionLost { _ = try await conn.execute("SELECT 2 AS N") }
            #expect(message?.contains("just started") == true)
            #expect(server.statements
                == Self.scope + ["SELECT 1 AS N", "SELECT 2 AS N"] + Self.scope + ["SELECT 2 AS N"])
            // Usable still: the next statement starts a fresh session on the scope.
            server.reply(answer("s3", started: true, [statusSet("ok")]))
            server.reply(answer("s3", [statusSet("ok")]))
            server.reply(answer("s3", [numberSet("N", 3)]))
            let result = try await conn.execute("SELECT 3 AS N")
            #expect(result.rows.first?["N"] == .int(3))
            let executes = server.executes
            try #require(executes.count == 10)
            #expect(executes[7].sessionId == nil)
            server.reply(released)
            await conn.close()
        }
    }

    @Test func aLostSessionWithAnOpenTransactionIsReportedNotReplaced() async throws {
        try await withServer { server in
            let conn = try await opened(server)
            server.reply(answer("s1", [statusSet("ok")]))
            try await conn.begin()
            server.reply(sessionGone("s1"), status: 404)
            let message = await sessionLost { _ = try await conn.execute("INSERT INTO t VALUES (1)") }
            #expect(message?.contains("transaction") == true)
            #expect(await !conn.isClosed)
            #expect(server.statements
                == Self.scope + ["SELECT 1 AS N", "BEGIN", "INSERT INTO t VALUES (1)"])
            // The next statement starts over on the DSN's scope.
            server.reply(answer("s2", started: true, [statusSet("ok")]))
            server.reply(answer("s2", [statusSet("ok")]))
            server.reply(answer("s2", [statusSet("ok")]))
            try await conn.rollback()
            #expect(server.statements.suffix(3) == Self.scope + ["ROLLBACK"])
            #expect(await conn.autoCommit)
            server.reply(released)
            await conn.close()
        }
    }

    @Test func aTransactionOpenedByAStatementIsGuardedTheSameWay() async throws {
        try await withServer { server in
            let conn = try await opened(server)
            server.reply(answer("s1", [statusSet("ok")]))
            _ = try await conn.execute("BEGIN TRANSACTION")
            server.reply(sessionGone("s1"), status: 404)
            let message = await sessionLost { _ = try await conn.execute("INSERT INTO t VALUES (1)") }
            #expect(message?.contains("transaction") == true)
            #expect(server.pending == 0)
            await conn.close()
        }
    }

    @Test func autocommitOffIsATransactionOnceTheSessionRanUnderIt() async throws {
        try await withServer { server in
            let conn = try await opened(server)
            await conn.setAutoCommit(false)
            // The lost session never ran anything with autocommit off, so it held no
            // transaction and is replaced.
            server.reply(sessionGone("s1"), status: 404)
            server.reply(answer("s2", started: true, [statusSet("ok")]))
            server.reply(answer("s2", [statusSet("ok")]))
            server.reply(answer("s2", [numberSet("N", 2)]))
            _ = try await conn.execute("INSERT INTO t VALUES (2)")
            // This one did, and its implicit transaction went with it.
            server.reply(sessionGone("s2"), status: 404)
            let message = await sessionLost { _ = try await conn.execute("INSERT INTO t VALUES (3)") }
            #expect(message?.contains("transaction") == true)
            #expect(server.executes.suffix(4).allSatisfy { $0.autoCommit == false })
            await conn.close()
        }
    }

    @Test func aTransactionACommitEndedIsNoReasonToRefuse() async throws {
        try await withServer { server in
            let conn = try await opened(server)
            server.reply(answer("s1", [statusSet("ok")]))
            server.reply(answer("s1", [statusSet("ok")]))
            _ = try await conn.execute("BEGIN")
            _ = try await conn.execute("COMMIT")
            server.reply(sessionGone("s1"), status: 404)
            server.reply(answer("s2", started: true, [statusSet("ok")]))
            server.reply(answer("s2", [statusSet("ok")]))
            server.reply(answer("s2", [numberSet("N", 2)]))
            let result = try await conn.execute("SELECT 2 AS N")
            #expect(result.rows.first?["N"] == .int(2))
            server.reply(released)
            await conn.close()
        }
    }

    @Test func aLostSessionWhoseContextMovedIsReportedNotReplaced() async throws {
        try await withServer { server in
            let conn = try await opened(server)
            server.reply(answer("s1", [statusSet("ok")]))
            _ = try await conn.execute("USE SCHEMA OTHER")
            server.reply(sessionGone("s1"), status: 404)
            let message = await sessionLost { _ = try await conn.execute("SELECT * FROM t") }
            #expect(message?.contains("context") == true)
            #expect(server.statements
                == Self.scope + ["SELECT 1 AS N", "USE SCHEMA OTHER", "SELECT * FROM t"])
            // The next statement starts over on the DSN's scope.
            server.reply(answer("s2", started: true, [statusSet("ok")]))
            server.reply(answer("s2", [statusSet("ok")]))
            server.reply(answer("s2", [numberSet("N", 2)]))
            _ = try await conn.execute("SELECT 2 AS N")
            #expect(server.statements.suffix(3) == Self.scope + ["SELECT 2 AS N"])
            server.reply(released)
            await conn.close()
        }
    }

    @Test(arguments: [
        "SET v = 1",
        "ALTER SESSION SET TIMEZONE = 'UTC'",
        "CREATE TEMPORARY TABLE scratch (a INT)",
        "SELECT 1; USE SCHEMA OTHER",
    ])
    func aVariableASettingOrATemporaryObjectIsContextToo(_ statement: String) async throws {
        try await withServer { server in
            let conn = try await opened(server)
            server.reply(answer("s1", [statusSet("ok")]))
            _ = try await conn.execute(statement, multiStatementCount: 0)
            server.reply(sessionGone("s1"), status: 404)
            let message = await sessionLost { _ = try await conn.execute("SELECT 2") }
            #expect(message?.contains("context") == true)
            await conn.close()
            #expect(server.pending == 0)
        }
    }

    @Test func anOrdinaryStatementLeavesNothingAReplacementWouldMiss() async throws {
        try await withServer { server in
            let conn = try await opened(server)
            server.reply(answer("s1", [statusSet("ok")]))
            _ = try await conn.execute("CREATE TABLE t (a INT)")
            server.reply(sessionGone("s1"), status: 404)
            server.reply(answer("s2", started: true, [statusSet("ok")]))
            server.reply(answer("s2", [statusSet("ok")]))
            server.reply(answer("s2", [numberSet("N", 2)]))
            let result = try await conn.execute("SELECT 2 AS N")
            #expect(result.rows.first?["N"] == .int(2))
            server.reply(released)
            await conn.close()
        }
    }

    @Test func beginOnALostSessionIsResentOnAFreshOne() async throws {
        try await withServer { server in
            let conn = try await opened(server)
            server.reply(sessionGone("s1"), status: 404)
            server.reply(answer("s2", started: true, [statusSet("ok")]))
            server.reply(answer("s2", [statusSet("ok")]))
            server.reply(answer("s2", [statusSet("ok")]))
            try await conn.begin()
            #expect(server.statements
                == Self.scope + ["SELECT 1 AS N", "BEGIN"] + Self.scope + ["BEGIN"])
            // Both went out with autocommit off, the mode the transaction runs in.
            let executes = server.executes
            try #require(executes.count == 7)
            #expect(executes[3].autoCommit == false)
            #expect(executes[6].autoCommit == false)
            server.reply(released)
            await conn.close()
        }
    }

    @Test func aCommitWhoseSessionIsGoneIsReportedNotResent() async throws {
        try await withServer { server in
            let conn = try await opened(server)
            server.reply(answer("s1", [statusSet("ok")]))
            try await conn.begin()
            server.reply(sessionGone("s1"), status: 404)
            let message = await sessionLost { try await conn.commit() }
            #expect(message?.contains("transaction") == true)
            #expect(server.statements == Self.scope + ["SELECT 1 AS N", "BEGIN", "COMMIT"])
            await conn.close()
        }
    }

    @Test func closingReleasesTheSessionWithOneDelete() async throws {
        try await withServer { server in
            let conn = try await opened(server)
            server.reply(released)
            await conn.close()
            let last = server.sent.last
            #expect(last?.method == "DELETE")
            #expect(last?.path == "/api/sessions/s1")
            #expect(server.pending == 0)
            let count = server.sent.count
            await conn.close()
            #expect(server.sent.count == count)
            #expect(await conn.sessionId == nil)
            await #expect(throws: FrostlakeError.connectionClosed) {
                _ = try await conn.execute("SELECT 1")
            }
        }
    }

    @Test func closingBeforeAnyStatementSendsNothing() async throws {
        try await withServer { server in
            let conn = try await Frostlake.connect(server.dsn("/APP?schema=PUBLIC"))
            await conn.close()
            #expect(server.sent.isEmpty)
        }
    }

    enum ReleaseFailure: String, CaseIterable, Sendable {
        case notFound, methodNotAllowed, closedSocket, noAnswer
    }

    @Test(.timeLimit(.minutes(1)), arguments: ReleaseFailure.allCases)
    func aReleaseThatFailsIsNoFailureOfClose(_ failure: ReleaseFailure) async throws {
        try await withServer { server in
            let conn = try await opened(server)
            switch failure {
            case .notFound:
                server.reply(#"{"success":false,"errorMessage":"Session 's1' does not exist or has expired.","sessionId":null}"#,
                             status: 404)
            case .methodNotAllowed:
                server.reply("", status: 405)
            case .closedSocket:
                server.drop()
            case .noAnswer:
                server.hang()
            }
            await conn.close()
            #expect(server.sent.filter { $0.method == "DELETE" }.count == 1)
            #expect(await conn.isClosed)
        }
    }
}

@Suite struct SessionTextTests {

    @Test(arguments: [
        "USE SCHEMA s",
        "SET v = 1",
        "UNSET v",
        "ALTER SESSION SET TIMEZONE = 'UTC'",
        "CREATE DATABASE d",
        "DROP SCHEMA IF EXISTS s",
        "CREATE TEMPORARY TABLE t (a INT)",
        "create or replace temp stage st",
        "CREATE LOCAL VOLATILE TABLE t (a INT)",
        "CREATE OR REPLACE SECURE TEMPORARY VIEW v AS SELECT 1",
        "-- note\nCREATE TEMP TABLE t (a INT)",
    ])
    func statementsThatLeaveStateOnTheSession(_ statement: String) {
        #expect(SessionText.touchesSession(statement))
    }

    @Test(arguments: [
        "SELECT 1",
        "CREATE TABLE t (a INT)",
        "CREATE TRANSIENT TABLE t (a INT)",
        "CREATE TABLE temp (a INT)",
        "DROP TABLE t",
        "ALTER TABLE t ADD COLUMN b INT",
        "SELECT 'USE SCHEMA s'",
    ])
    func statementsThatLeaveNothingBehind(_ statement: String) {
        #expect(!SessionText.touchesSession(statement))
    }

    @Test func whereATransactionBeginsAndEnds() {
        for statement in ["BEGIN", "begin transaction", "BEGIN WORK", "BEGIN NAME t1", "START TRANSACTION"] {
            #expect(SessionText.transactionEffect(statement) == .begins, "\(statement)")
        }
        for statement in ["COMMIT", "ROLLBACK", "commit work"] {
            #expect(SessionText.transactionEffect(statement) == .ends, "\(statement)")
        }
        // BEGIN followed by a statement opens a scripting block instead.
        for statement in ["BEGIN SELECT 1", "SELECT 1", "BEGINNING", "SELECT 'BEGIN'"] {
            #expect(SessionText.transactionEffect(statement) == .none, "\(statement)")
        }
    }

    @Test func aRequestSplitsOnlyOnItsOwnSemicolons() {
        #expect(SessionText.statements("SELECT 1; USE SCHEMA s") == ["SELECT 1", " USE SCHEMA s"])
        #expect(SessionText.statements("SELECT 'a;b'; ") == ["SELECT 'a;b'"])
        #expect(SessionText.statements("SELECT $$a;b$$ -- c;d\n") == ["SELECT $$a;b$$ -- c;d\n"])
    }
}
