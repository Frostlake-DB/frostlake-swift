import Foundation
import Testing
@testable import Frostlake

@Suite struct BindFormatTests {

    @Test func scalars() throws {
        #expect(try FrostlakeBind.null.literal() == "NULL")
        #expect(try FrostlakeBind.bool(true).literal() == "true")
        #expect(try FrostlakeBind.bool(false).literal() == "false")
        #expect(try FrostlakeBind.int(-42).literal() == "-42")
        #expect(try FrostlakeBind.double(2.5).literal() == "2.5")
        #expect(try FrostlakeBind.decimal(Decimal(string: "1234.5678")!).literal() == "1234.5678")
    }

    @Test func nonFiniteDoubleRefused() {
        #expect(throws: FrostlakeError.binds("non-finite number inf")) {
            _ = try FrostlakeBind.double(.infinity).literal()
        }
        #expect(throws: FrostlakeError.self) {
            _ = try FrostlakeBind.double(.nan).literal()
        }
    }

    @Test func stringEscapesBackslashAndQuote() throws {
        #expect(try FrostlakeBind.string("plain").literal() == "'plain'")
        #expect(try FrostlakeBind.string(#"it's a \ test"#).literal() == #"'it''s a \\ test'"#)
        // A trailing backslash must not break out of the literal.
        #expect(try FrostlakeBind.string("end\\").literal() == #"'end\\'"#)
    }

    @Test func temporals() throws {
        let ts = Date(timeIntervalSince1970: 1_767_323_045.123)   // 2026-01-02 03:04:05.123 UTC
        #expect(try FrostlakeBind.timestamp(ts).literal() == "'2026-01-02T03:04:05.123'::TIMESTAMP_NTZ")
        #expect(try FrostlakeBind.date(ts).literal() == "'2026-01-02'::DATE")
        let preEpoch = Date(timeIntervalSince1970: -14_182_940)   // 1969-07-20 20:17:40 UTC
        #expect(try FrostlakeBind.timestamp(preEpoch).literal() == "'1969-07-20T20:17:40.000'::TIMESTAMP_NTZ")
        #expect(try FrostlakeBind.date(preEpoch).literal() == "'1969-07-20'::DATE")
    }

    @Test func binary() throws {
        #expect(try FrostlakeBind.binary(Data([0xDE, 0xAD, 0xBE, 0xEF])).literal() == "X'DEADBEEF'")
        #expect(try FrostlakeBind.binary(Data()).literal() == "X''")
    }

    @Test func arrays() throws {
        let bind: FrostlakeBind = [1, "a", nil]
        #expect(try bind.literal() == "[1, 'a', NULL]")
        #expect(try FrostlakeBind.array([.array([.int(1)])]).literal() == "[[1]]")
    }

    @Test func literalConformances() throws {
        let binds: [FrostlakeBind] = [1, "x", 3.5, true, nil]
        #expect(binds[0] == .int(1))
        #expect(binds[1] == .string("x"))
        #expect(binds[2] == .double(3.5))
        #expect(binds[3] == .bool(true))
        #expect(binds[4] == .null)
    }
}
