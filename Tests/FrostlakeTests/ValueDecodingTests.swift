import Foundation
import Testing
@testable import Frostlake

@Suite struct ValueDecodingTests {

    private func column(_ dataType: String, scale: Int = 0) -> FrostlakeColumn {
        FrostlakeColumn(name: "C", dataType: dataType, nullable: true, precision: 38, scale: scale)
    }

    @Test func integralNumber() {
        #expect(ValueDecoding.decode(.number("42"), column: column("NUMBER")) == .int(42))
        #expect(ValueDecoding.decode(.number("9223372036854775807"), column: column("NUMBER"))
            == .int(Int64.max))
        #expect(ValueDecoding.decode(.number("-7"), column: column("NUMBER")) == .int(-7))
    }

    @Test func beyondInt64FallsBackToDecimal() {
        let v = ValueDecoding.decode(.number("9223372036854775808"), column: column("NUMBER"))
        #expect(v == .decimal(Decimal(string: "9223372036854775808")!))
    }

    @Test func scaledNumberIsExactDecimal() {
        #expect(ValueDecoding.decode(.number("3.14"), column: column("NUMBER", scale: 2))
            == .decimal(Decimal(string: "3.14")!))
        let big = "12345678901234567890.123456789012345678"
        let v = ValueDecoding.decode(.number(big), column: column("NUMBER", scale: 18))
        #expect("\(v)" == big)   // all 38 digits survive
    }

    @Test func floatIsDouble() {
        #expect(ValueDecoding.decode(.number("3.5"), column: column("FLOAT")) == .double(3.5))
        #expect(ValueDecoding.decode(.number("1e10"), column: column("DOUBLE")) == .double(1e10))
    }

    @Test func passthroughKinds() {
        #expect(ValueDecoding.decode(.bool(true), column: column("BOOLEAN")) == .bool(true))
        #expect(ValueDecoding.decode(.string("x"), column: column("VARCHAR")) == .string("x"))
        #expect(ValueDecoding.decode(.null, column: column("NUMBER")) == .null)
        #expect(ValueDecoding.decode(.string("2026-01-02"), column: column("DATE"))
            == .string("2026-01-02"))
        #expect(ValueDecoding.decode(.string("[1,2]"), column: column("ARRAY")) == .string("[1,2]"))
    }

    @Test func binaryHexDecodes() {
        #expect(ValueDecoding.decode(.string("DEADBEEF"), column: column("BINARY"))
            == .binary(Data([0xDE, 0xAD, 0xBE, 0xEF])))
        #expect(ValueDecoding.decode(.string("deadbeef"), column: column("BINARY"))
            == .binary(Data([0xDE, 0xAD, 0xBE, 0xEF])))
        #expect(ValueDecoding.decode(.string(""), column: column("BINARY")) == .binary(Data()))
        // Non-hex text on a BINARY column stays text rather than being mangled.
        #expect(ValueDecoding.decode(.string("zz"), column: column("BINARY")) == .string("zz"))
        #expect(ValueDecoding.decode(.string("ABC"), column: column("BINARY")) == .string("ABC"))
    }

    @Test func structuredWireValuesRenderAsText() {
        #expect(ValueDecoding.decode(.array([.number("1"), .number("2")]), column: column("ARRAY"))
            == .string("[1,2]"))
        #expect(ValueDecoding.decode(.object(["k": .number("1")]), column: column("OBJECT"))
            == .string("{\"k\":1}"))
    }

    @Test func accessors() {
        #expect(FrostlakeValue.int(42).decimalValue == Decimal(42))
        #expect(FrostlakeValue.int(42).doubleValue == 42)
        #expect(FrostlakeValue.decimal(Decimal(string: "42")!).intValue == 42)
        #expect(FrostlakeValue.decimal(Decimal(string: "3.5")!).intValue == nil)
        #expect(FrostlakeValue.double(2).intValue == 2)
        #expect(FrostlakeValue.double(2.5).intValue == nil)
        #expect(FrostlakeValue.string("x").intValue == nil)
        #expect(FrostlakeValue.null.isNull)
        #expect(FrostlakeValue.bool(true).boolValue == true)
        #expect(FrostlakeValue.binary(Data([1])).binaryValue == Data([1]))
        #expect(FrostlakeValue.string("2026-01-02 03:04:05").timestampValue
            == Date(timeIntervalSince1970: 1_767_323_045))
        #expect(FrostlakeValue.string("2026-01-02 03:04:05").dateValue
            == Date(timeIntervalSince1970: 1_767_312_000))
        #expect(FrostlakeValue.string("03:04:05").timeValue == 11_045)
    }

    @Test func descriptions() {
        #expect("\(FrostlakeValue.null)" == "NULL")
        #expect("\(FrostlakeValue.int(7))" == "7")
        #expect("\(FrostlakeValue.string("x"))" == "x")
        #expect("\(FrostlakeValue.binary(Data([0xAB])))" == "AB")
    }
}
