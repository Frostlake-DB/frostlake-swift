import Testing
@testable import Frostlake

@Suite struct ConfigTests {

    @Test func fullDsn() throws {
        let cfg = try FrostlakeConfig(dsn: "frostlake://localhost:18082/MY_DB?schema=PUBLIC")
        #expect(cfg.baseUrl == "http://localhost:18082")
        #expect(cfg.database == "MY_DB")
        #expect(cfg.schema == "PUBLIC")
    }

    @Test func frostlakeSchemeDefaultsPort18082() throws {
        let cfg = try FrostlakeConfig(dsn: "frostlake://db.example.com/SALES")
        #expect(cfg.baseUrl == "http://db.example.com:18082")
        #expect(cfg.database == "SALES")
        #expect(cfg.schema == nil)
    }

    @Test func httpSchemeKeepsUrlPortSemantics() throws {
        let noPort = try FrostlakeConfig(dsn: "http://h/db")
        #expect(noPort.baseUrl == "http://h")
        #expect(noPort.database == "db")
        let withPort = try FrostlakeConfig(dsn: "http://h:9/")
        #expect(withPort.baseUrl == "http://h:9")
        #expect(withPort.database == nil)
    }

    @Test func hostOnly() throws {
        let cfg = try FrostlakeConfig(dsn: "frostlake://localhost")
        #expect(cfg.baseUrl == "http://localhost:18082")
        #expect(cfg.database == nil)
        #expect(cfg.schema == nil)
    }

    @Test func pathSlashesTrimmed() throws {
        let cfg = try FrostlakeConfig(dsn: "frostlake://h//a/b//")
        #expect(cfg.database == "a/b")
    }

    @Test func rejectsOtherSchemes() {
        #expect(throws: FrostlakeError.invalidDSN("DSN must start with frostlake:// or http://")) {
            _ = try FrostlakeConfig(dsn: "ftp://h/db")
        }
    }

    @Test func rejectsGarbage() {
        #expect(throws: FrostlakeError.self) {
            _ = try FrostlakeConfig(dsn: "not a url")
        }
    }

    @Test func rejectsMissingHost() {
        #expect(throws: FrostlakeError.invalidDSN("DSN is missing host[:port]")) {
            _ = try FrostlakeConfig(dsn: "frostlake:///db")
        }
    }

    @Test func identifierQuoting() {
        #expect(quoteIdentifier("MY_DB") == "MY_DB")
        #expect(quoteIdentifier("my_db") == "my_db")
        #expect(quoteIdentifier("_x$1") == "_x$1")
        #expect(quoteIdentifier("my-db") == "\"my-db\"")
        #expect(quoteIdentifier("1x") == "\"1x\"")
        #expect(quoteIdentifier("a\"b") == "\"a\"\"b\"")
        #expect(quoteIdentifier("") == "\"\"")
    }
}
