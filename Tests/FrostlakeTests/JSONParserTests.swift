import Foundation
import Testing
@testable import Frostlake

@Suite struct JSONParserTests {

    private func parse(_ text: String) throws -> JSONValue {
        try JSONParser.parse(Data(text.utf8))
    }

    @Test func scalars() throws {
        #expect(try parse("true") == .bool(true))
        #expect(try parse("false") == .bool(false))
        #expect(try parse("null") == .null)
        #expect(try parse("42") == .number("42"))
        #expect(try parse("\"x\"") == .string("x"))
        #expect(try parse("  1  ") == .number("1"))
    }

    @Test func numbersKeepRawText() throws {
        let big = "12345678901234567890.123456789012345678"
        #expect(try parse("[\(big)]") == .array([.number(big)]))
        #expect(try parse("-1.5e-3") == .number("-1.5e-3"))
        #expect(try parse("9223372036854775807") == .number("9223372036854775807"))
    }

    @Test func stringEscapes() throws {
        #expect(try parse(#""a\nb\tc""#) == .string("a\nb\tc"))
        #expect(try parse(#""\"\\\/""#) == .string("\"\\/"))
        #expect(try parse(#""A""#) == .string("A"))
        #expect(try parse(#""😀""#) == .string("😀"))
        #expect(try parse(#""\b\f""#) == .string("\u{08}\u{0C}"))
    }

    @Test func utf8Passthrough() throws {
        #expect(try parse("\"héj 😀\"") == .string("héj 😀"))
    }

    @Test func structures() throws {
        #expect(try parse("[]") == .array([]))
        #expect(try parse("{}") == .object([:]))
        #expect(try parse(#"{"a":[1,null,{"b":true}]}"#)
            == .object(["a": .array([.number("1"), .null, .object(["b": .bool(true)])])]))
    }

    @Test func realEnvelopeParses() throws {
        let body = #"{"errorMessage":null,"executionTimeMs":33,"resultSets":[{"columns":[{"dataType":"NUMBER","name":"BIG","nullable":false,"precision":38,"scale":18}],"rowCount":1,"rows":[[12345678901234567890.123456789012345678]]}],"sessionId":"22c46532","success":true}"#
        let root = try parse(body)
        let fields = root.objectOrNil
        #expect(fields?["success"] == .bool(true))
        let sets = fields?["resultSets"]?.arrayOrNil
        let rows = sets?.first?.objectOrNil?["rows"]?.arrayOrNil
        #expect(rows?.first?.arrayOrNil?.first == .number("12345678901234567890.123456789012345678"))
    }

    @Test func malformedInputs() {
        #expect(throws: JSONParseError.self) { _ = try parse("1 2") }
        #expect(throws: JSONParseError.self) { _ = try parse("tru") }
        #expect(throws: JSONParseError.self) { _ = try parse("\"abc") }
        #expect(throws: JSONParseError.self) { _ = try parse(#""\ud83d""#) }
        #expect(throws: JSONParseError.self) { _ = try parse("\"a\u{01}b\"") }
        #expect(throws: JSONParseError.self) { _ = try parse("{\"a\" 1}") }
        #expect(throws: JSONParseError.self) { _ = try parse("[1,]") }
        #expect(throws: JSONParseError.self) { _ = try parse("") }
        #expect(throws: JSONParseError.self) { _ = try parse("-") }
        #expect(throws: JSONParseError.self) { _ = try parse("1.") }
    }

    @Test func nestingDepthIsBounded() {
        let deep = String(repeating: "[", count: 600)
        #expect(throws: JSONParseError.self) { _ = try parse(deep) }
    }
}
