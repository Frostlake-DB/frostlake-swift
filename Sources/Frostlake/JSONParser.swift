import Foundation

struct JSONParseError: Error, Equatable, CustomStringConvertible {
    let message: String
    let offset: Int

    var description: String { "\(message) at byte \(offset)" }
}

/// Minimal recursive-descent JSON parser over UTF-8 bytes. It exists — instead
/// of JSONDecoder — so number literals keep their exact wire text; see
/// JSONValue for why that matters.
struct JSONParser {
    private let bytes: [UInt8]
    private var i = 0

    static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.i == parser.bytes.count else {
            throw JSONParseError(message: "trailing characters", offset: parser.i)
        }
        return value
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private mutating func skipWhitespace() {
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { i += 1 } else { break }
        }
    }

    private mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth < 512 else {
            throw JSONParseError(message: "nesting too deep", offset: i)
        }
        guard i < bytes.count else {
            throw JSONParseError(message: "unexpected end of input", offset: i)
        }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    private mutating func expect(_ word: String) throws {
        for expected in word.utf8 {
            guard i < bytes.count, bytes[i] == expected else {
                throw JSONParseError(message: "invalid literal", offset: i)
            }
            i += 1
        }
    }

    private mutating func parseNumber() throws -> String {
        let start = i
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        let intDigits = consumeDigits()
        guard intDigits > 0 else {
            throw JSONParseError(message: "invalid number", offset: start)
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            guard consumeDigits() > 0 else {
                throw JSONParseError(message: "invalid number", offset: start)
            }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard consumeDigits() > 0 else {
                throw JSONParseError(message: "invalid number", offset: start)
            }
        }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    private mutating func consumeDigits() -> Int {
        let start = i
        while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") { i += 1 }
        return i - start
    }

    private mutating func parseString() throws -> String {
        i += 1   // opening quote
        var out: [UInt8] = []
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "\"") {
                i += 1
                return String(decoding: out, as: UTF8.self)
            }
            if b == UInt8(ascii: "\\") {
                i += 1
                try parseEscape(into: &out)
                continue
            }
            guard b >= 0x20 else {
                throw JSONParseError(message: "unescaped control character in string", offset: i)
            }
            out.append(b)
            i += 1
        }
        throw JSONParseError(message: "unterminated string", offset: i)
    }

    private mutating func parseEscape(into out: inout [UInt8]) throws {
        guard i < bytes.count else {
            throw JSONParseError(message: "unterminated escape", offset: i)
        }
        let b = bytes[i]
        i += 1
        switch b {
        case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
        case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
        case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
        case UInt8(ascii: "b"): out.append(0x08)
        case UInt8(ascii: "f"): out.append(0x0C)
        case UInt8(ascii: "n"): out.append(0x0A)
        case UInt8(ascii: "r"): out.append(0x0D)
        case UInt8(ascii: "t"): out.append(0x09)
        case UInt8(ascii: "u"):
            var code = try parseHex4()
            if code >= 0xD800, code <= 0xDBFF {   // high surrogate: a low one must follow
                guard i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else {
                    throw JSONParseError(message: "unpaired surrogate", offset: i)
                }
                i += 2
                let low = try parseHex4()
                guard low >= 0xDC00, low <= 0xDFFF else {
                    throw JSONParseError(message: "unpaired surrogate", offset: i)
                }
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
            }
            guard let scalar = Unicode.Scalar(code) else {
                throw JSONParseError(message: "invalid unicode escape", offset: i)
            }
            out.append(contentsOf: Array(String(scalar).utf8))
        default:
            throw JSONParseError(message: "invalid escape", offset: i - 1)
        }
    }

    private mutating func parseHex4() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard i < bytes.count, let digit = hexDigit(bytes[i]) else {
                throw JSONParseError(message: "invalid unicode escape", offset: i)
            }
            value = value << 4 | digit
            i += 1
        }
        return value
    }

    private func hexDigit(_ b: UInt8) -> UInt32? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(b - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(b - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(b - UInt8(ascii: "A")) + 10
        default: return nil
        }
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
        i += 1   // "{"
        var out: [String: JSONValue] = [:]
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
            i += 1
            return .object(out)
        }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else {
                throw JSONParseError(message: "expected object key", offset: i)
            }
            let key = try parseString()
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else {
                throw JSONParseError(message: "expected ':'", offset: i)
            }
            i += 1
            skipWhitespace()
            out[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            guard i < bytes.count else {
                throw JSONParseError(message: "unterminated object", offset: i)
            }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            if bytes[i] == UInt8(ascii: "}") {
                i += 1
                return .object(out)
            }
            throw JSONParseError(message: "expected ',' or '}'", offset: i)
        }
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
        i += 1   // "["
        var out: [JSONValue] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") {
            i += 1
            return .array(out)
        }
        while true {
            skipWhitespace()
            out.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard i < bytes.count else {
                throw JSONParseError(message: "unterminated array", offset: i)
            }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            if bytes[i] == UInt8(ascii: "]") {
                i += 1
                return .array(out)
            }
            throw JSONParseError(message: "expected ',' or ']'", offset: i)
        }
    }
}
