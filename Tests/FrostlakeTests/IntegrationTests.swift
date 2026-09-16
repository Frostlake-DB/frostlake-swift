import Foundation
import Testing
@testable import Frostlake

/// Live-engine tests. Enabled when FROSTLAKE_URL or FROSTLAKE_CLASSPATH is
/// set (see TestServer); serialized because they share one server. Object
/// names carry a per-run tag so a long-lived shared server can rerun them.
@Suite(.enabled(if: TestEnvironment.available), .serialized)
struct IntegrationTests {

    private func open(database: String? = nil, schema: String? = nil) async throws -> FrostlakeConnection {
        try await Frostlake.connect(TestServer.shared.dsn(database: database, schema: schema))
    }

    private func name(_ base: String) -> String {
        "SWIFT_\(base)_\(TestEnvironment.runTag)"
    }

    @Test func connectPingAndSession() async throws {
        let conn = try await open()
        let before = await conn.sessionId
        #expect(before == nil)
        let result = try await conn.execute("SELECT 1 AS ONE")
        #expect(result.rows[0]["ONE"] == .int(1))
        #expect(result.executionTimeMs >= 0)
        let first = await conn.sessionId
        #expect(first != nil)
        _ = try await conn.execute("SELECT 2")
        let second = await conn.sessionId
        #expect(second == first)
        await conn.close()
        await #expect(throws: FrostlakeError.connectionClosed) {
            _ = try await conn.execute("SELECT 1")
        }
    }

    @Test func unreachableServerFailsToConnect() async {
        await #expect(throws: FrostlakeError.self) {
            _ = try await Frostlake.connect("frostlake://localhost:1/")
        }
    }

    @Test func scalarTypes() async throws {
        let conn = try await open()
        let result = try await conn.execute(
            "SELECT 42 AS I, 'it''s héj' AS S, 3.14 AS DEC, TRUE AS B, NULL AS N, 3.5::FLOAT AS F")
        let row = result.rows[0]
        #expect(row["I"] == .int(42))
        #expect(row["S"] == .string("it's héj"))
        #expect(row["DEC"] == .decimal(Decimal(string: "3.14")!))
        #expect(row["B"] == .bool(true))
        #expect(row["N"] == .null)
        #expect(row["F"] == .double(3.5))
        #expect(row["i"] == .int(42))   // case-insensitive lookup
        #expect(result.columns[0].name == "I")
        #expect(result.columns[0].dataType == "NUMBER")
    }

    @Test(.enabled("engine sends no column length", { await TestServer.shared.reportsColumnLength() }))
    func textAndBinaryColumnsReportTheirDeclaredLength() async throws {
        let conn = try await open()
        let t = name("WIDTHS")
        _ = try await conn.execute(
            "CREATE OR REPLACE TABLE \(t) (S VARCHAR(9), B BINARY(5), BIG VARCHAR, N NUMBER(10,2))")
        let result = try await conn.execute("SELECT S, B, BIG, N FROM \(t)")
        #expect(result.columns[0].length == 9)
        #expect(result.columns[1].length == 5)
        #expect(result.columns[2].length == 16777216)
        #expect(result.columns[3].length == nil)
        _ = try await conn.execute("DROP TABLE \(t)")
    }

    @Test func decimalPrecisionSurvives38Digits() async throws {
        let conn = try await open()
        let text = "12345678901234567890.123456789012345678"
        let result = try await conn.execute("SELECT '\(text)'::NUMBER(38,18) AS BIG, 9223372036854775807 AS MAXI")
        #expect("\(result.rows[0]["BIG"]!)" == text)
        #expect(result.rows[0]["MAXI"] == .int(Int64.max))
    }

    @Test func dmlCounts() async throws {
        let conn = try await open()
        let t = name("DML")
        let create = try await conn.execute("CREATE OR REPLACE TABLE \(t) (I INT, S VARCHAR)")
        #expect(create.updateCount == nil)
        let insert = try await conn.execute("INSERT INTO \(t) VALUES (1, 'a'), (2, 'b'), (3, 'c')")
        #expect(insert.updateCount == 3)
        #expect(insert.rowCount == 3)
        // The engine's own count row stays readable.
        #expect(insert.columns.map { $0.name.lowercased() } == ["number of rows inserted"])
        #expect(insert.rows.first?[0] == .int(3))
        let update = try await conn.execute("UPDATE \(t) SET S = 'z' WHERE I <= 2")
        #expect(update.updateCount == 2)
        let delete = try await conn.execute("DELETE FROM \(t) WHERE I = 3")
        #expect(delete.updateCount == 1)
        let nothing = try await conn.execute("DELETE FROM \(t) WHERE I = 42")
        #expect(nothing.updateCount == 0)
        let rows = try await conn.execute("SELECT I, S FROM \(t) ORDER BY I")
        #expect(rows.updateCount == nil)
        #expect(rows.rowCount == 2)
        #expect(rows.rows[0]["S"] == .string("z"))
        _ = try await conn.execute("DROP TABLE \(t)")
    }

    @Test func mergeCountsInsertedPlusUpdated() async throws {
        let conn = try await open()
        let target = name("MRG_T")
        let source = name("MRG_S")
        _ = try await conn.execute("CREATE OR REPLACE TABLE \(target) (I INT, S VARCHAR)")
        _ = try await conn.execute("INSERT INTO \(target) VALUES (1, 'old'), (2, 'keep')")
        _ = try await conn.execute("CREATE OR REPLACE TABLE \(source) (I INT, S VARCHAR)")
        _ = try await conn.execute("INSERT INTO \(source) VALUES (1, 'new'), (3, 'ins')")
        let merge = try await conn.execute("""
            MERGE INTO \(target) t USING \(source) s ON t.I = s.I
            WHEN MATCHED THEN UPDATE SET t.S = s.S
            WHEN NOT MATCHED THEN INSERT (I, S) VALUES (s.I, s.S)
            """)
        #expect(merge.rowCount == 2)
        #expect(merge.updateCount == 2)
        _ = try await conn.execute("DROP TABLE \(target)")
        _ = try await conn.execute("DROP TABLE \(source)")
    }

    /// Only an engine that reports each statement's update count can tell a query that renames its
    /// column to a count name from DML; against an older one this reports as skipped.
    @Test(.enabled("engine sends no update count", { await TestServer.shared.reportsUpdateCount() }))
    func aQueryNamedLikeACountIsStillAQuery() async throws {
        let conn = try await open()
        let aliased = try await conn.execute("SELECT 9 AS \"number of rows inserted\"")
        #expect(aliased.updateCount == nil)
        #expect(aliased.rowCount == 1)
        #expect(aliased.rows.first?[0] == .int(9))
        let t = name("FLOW")
        _ = try await conn.execute("CREATE OR REPLACE TABLE \(t) (I INT)")
        let chained = try await conn.execute("INSERT INTO \(t) VALUES (1), (2) ->> SELECT * FROM $1")
        #expect(chained.updateCount == nil)
        #expect(chained.rows.first?[0] == .int(2))
        _ = try await conn.execute("DROP TABLE \(t)")
    }

    @Test func bindsRoundTrip() async throws {
        let conn = try await open()
        let t = name("BINDS")
        _ = try await conn.execute("""
            CREATE OR REPLACE TABLE \(t) (
                I INT, S VARCHAR, F DOUBLE, B BOOLEAN, BIN BINARY,
                TS TIMESTAMP_NTZ, D DATE, DEC NUMBER(20,4), NUL VARCHAR)
            """)
        let moment = Date(timeIntervalSince1970: 1_767_323_045.123)
        let inserted = try await conn.execute(
            "INSERT INTO \(t) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [
                .int(42),
                .string(#"it's a \ test 🙂"#),
                .double(2.5),
                .bool(true),
                .binary(Data([0xDE, 0xAD, 0xBE, 0xEF])),
                .timestamp(moment),
                .date(moment),
                .decimal(Decimal(string: "1234.5678")!),
                .null,
            ])
        #expect(inserted.rowCount == 1)
        let row = try await conn.execute("SELECT * FROM \(t)").rows[0]
        #expect(row["I"] == .int(42))
        #expect(row["S"] == .string(#"it's a \ test 🙂"#))
        #expect(row["F"] == .double(2.5))
        #expect(row["B"] == .bool(true))
        #expect(row["BIN"] == .binary(Data([0xDE, 0xAD, 0xBE, 0xEF])))
        #expect(row["DEC"] == .decimal(Decimal(string: "1234.5678")!))
        #expect(row["NUL"] == .null)
        let ts = row["TS"]?.timestampValue
        #expect(ts != nil && abs(ts!.timeIntervalSince1970 - 1_767_323_045.123) < 0.0005)
        #expect(row["D"]?.dateValue == Date(timeIntervalSince1970: 1_767_312_000))
        // A ? inside a string literal is not a placeholder.
        let literal = try await conn.execute("SELECT ? AS A, 'q?q' AS B", [7])
        #expect(literal.rows[0]["A"] == .int(7))
        #expect(literal.rows[0]["B"] == .string("q?q"))
        _ = try await conn.execute("DROP TABLE \(t)")
    }

    @Test func dsnDatabaseAndSchemaAreUsed() async throws {
        let admin = try await open()
        let db = name("DB")
        _ = try await admin.execute("CREATE OR REPLACE DATABASE \(db)")
        _ = try await admin.execute("CREATE SCHEMA IF NOT EXISTS \(db).S2")
        let conn = try await open(database: db, schema: "S2")
        let result = try await conn.execute("SELECT CURRENT_DATABASE() AS D, CURRENT_SCHEMA() AS S")
        #expect(result.rows[0]["D"] == .string(db))
        #expect(result.rows[0]["S"] == .string("S2"))
        _ = try await admin.execute("DROP DATABASE \(db)")
    }

    @Test func failedUseFromDsnStaysSticky() async throws {
        let conn = try await open(database: name("NO_SUCH_DB"))
        await #expect(throws: FrostlakeError.self) {
            _ = try await conn.execute("SELECT 1")
        }
        // The failed USE stays queued: later statements keep failing rather
        // than silently running against the server's default database.
        await #expect(throws: FrostlakeError.self) {
            _ = try await conn.execute("SELECT 1")
        }
    }

    @Test func multiStatementAnswersOneResultSetEach() async throws {
        let conn = try await open()
        // A request carrying more than one statement has to be asked for; 0 means any number.
        _ = try await conn.execute("ALTER SESSION SET MULTI_STATEMENT_COUNT = 0")
        let result = try await conn.execute("SELECT 1 AS A; SELECT 2 AS B")
        #expect(result.resultSets.count == 2)
        #expect(result.rows[0]["A"] == .int(1))
        #expect(result.resultSets[1].rows[0]["B"] == .int(2))
    }

    @Test func aPackCanDeclareItsOwnCountWithoutAskingTheSession() async throws {
        let conn = try await open()
        // No ALTER SESSION anywhere: the count rides on the call that needs it.
        let declared = try await conn.execute("SELECT 1 AS A; SELECT 2 AS B", multiStatementCount: 2)
        #expect(declared.resultSets.count == 2)
        #expect(declared.resultSets[1].rows[0]["B"] == .int(2))
        // 0 means any number.
        let any = try await conn.execute("SELECT 1; SELECT 2; SELECT 3", multiStatementCount: 0)
        #expect(any.resultSets.count == 3)
    }

    /// Only an engine that counts a request's statements refuses one, and this driver supports
    /// older engines that run any pack. Against one of those there is no refusal to observe, so
    /// this reports as skipped rather than passed.
    @Test(.enabled("engine does not enforce a statement count",
                   { await TestServer.shared.countsStatements() }))
    func aCountTheCallDoesNotHoldIsRefused() async throws {
        let conn = try await open()
        // A count the call does not hold is refused, in either direction.
        await #expect(throws: FrostlakeError.self) {
            _ = try await conn.execute("SELECT 1", multiStatementCount: 2)
        }
        // The count rode on the call that carried it, so the session's own is untouched: a pack
        // that declares nothing still fails on a session that never asked for one.
        let declared = try await conn.execute("SELECT 1 AS A; SELECT 2 AS B", multiStatementCount: 2)
        #expect(declared.resultSets.count == 2)
        await #expect(throws: FrostlakeError.self) {
            _ = try await conn.execute("SELECT 1 AS A; SELECT 2 AS B")
        }
    }

    @Test func sqlErrorSurfacesAndConnectionStaysUsable() async throws {
        let conn = try await open()
        do {
            _ = try await conn.execute("SELECT FROM WHERE")
            Issue.record("expected a FrostlakeError.sql")
        } catch let error as FrostlakeError {
            guard case .sql(let message) = error else {
                Issue.record("expected .sql, got \(error)")
                return
            }
            #expect(!message.isEmpty)
        }
        let after = try await conn.execute("SELECT 1 AS OK")
        #expect(after.rows[0]["OK"] == .int(1))
    }

    @Test func transactionRollbackAndCommit() async throws {
        let conn = try await open()
        let t = name("TXN")
        _ = try await conn.execute("CREATE OR REPLACE TABLE \(t) (I INT)")
        try await conn.begin()
        _ = try await conn.execute("INSERT INTO \(t) VALUES (1)")
        try await conn.rollback()
        let afterRollback = try await conn.execute("SELECT COUNT(*) AS C FROM \(t)")
        #expect(afterRollback.rows[0]["C"] == .int(0))
        try await conn.begin()
        _ = try await conn.execute("INSERT INTO \(t) VALUES (2)")
        try await conn.commit()
        let afterCommit = try await conn.execute("SELECT COUNT(*) AS C FROM \(t)")
        #expect(afterCommit.rows[0]["C"] == .int(1))
        let auto = await conn.autoCommit
        #expect(auto)
        _ = try await conn.execute("DROP TABLE \(t)")
    }

    @Test func concurrentExecutesShareOneSession() async throws {
        let conn = try await open()
        let db = name("CONC")
        _ = try await conn.execute("CREATE OR REPLACE DATABASE \(db)")
        _ = try await conn.execute("USE DATABASE \(db)")
        async let first = conn.execute("SELECT CURRENT_DATABASE() AS D")
        async let second = conn.execute("SELECT CURRENT_DATABASE() AS D")
        let (a, b) = try await (first, second)
        #expect(a.rows[0]["D"] == .string(db))
        #expect(b.rows[0]["D"] == .string(db))
        let admin = try await open()
        _ = try await admin.execute("DROP DATABASE \(db)")
    }

    @Test func temporalWireForms() async throws {
        let conn = try await open()
        let result = try await conn.execute("""
            SELECT '2026-01-02 03:04:05.123'::TIMESTAMP_NTZ AS NTZ,
                   '2026-01-02'::DATE AS D,
                   '03:04:05'::TIME AS T
            """)
        let row = result.rows[0]
        #expect(row["NTZ"] == .string("2026-01-02 03:04:05.123"))
        #expect(row["D"] == .string("2026-01-02"))
        #expect(row["T"] == .string("03:04:05"))
        #expect(row["NTZ"]?.timestampValue == Date(timeIntervalSince1970: 1_767_323_045.123))
        #expect(row["D"]?.dateValue == Date(timeIntervalSince1970: 1_767_312_000))
        #expect(row["T"]?.timeValue == 11_045)
        let ltz = try await conn.execute("SELECT '2026-01-02 03:04:05'::TIMESTAMP_LTZ AS L")
        // Wire form carries a trailing offset; the LOCAL part is the value.
        let parsed = ltz.rows[0]["L"]?.timestampValue
        #expect(parsed != nil)
    }

    @Test func semiStructuredArrivesAsText() async throws {
        let conn = try await open()
        let result = try await conn.execute(
            "SELECT ARRAY_CONSTRUCT(1, 2) AS A, OBJECT_CONSTRUCT('k', 1) AS O, PARSE_JSON('{\"a\":1}') AS V")
        let row = result.rows[0]
        #expect(row["A"] == .string("[1,2]"))
        #expect(row["O"] == .string("{\"k\":1}"))
        #expect(row["V"] == .string("{\"a\":1}"))
    }

    @Test func binaryRoundTripIncludingEmpty() async throws {
        let conn = try await open()
        let result = try await conn.execute("SELECT TO_BINARY('DEADBEEF', 'HEX') AS B")
        #expect(result.rows[0]["B"] == .binary(Data([0xDE, 0xAD, 0xBE, 0xEF])))
        let empty = try await conn.execute("SELECT TO_BINARY('', 'HEX') AS B")
        #expect(empty.rows[0]["B"] == .binary(Data()))
    }
}
