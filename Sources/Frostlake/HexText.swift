import Foundation

/// BINARY crosses the JSON wire as bare hex text; bind literals use X'…'.
enum HexText {
    static func encode(_ data: Data) -> String {
        var out = ""
        out.reserveCapacity(data.count * 2)
        for byte in data {
            out.append(Character(Unicode.Scalar(hexDigit(byte >> 4))))
            out.append(Character(Unicode.Scalar(hexDigit(byte & 0xF))))
        }
        return out
    }

    /// Decode even-length hex; empty text is an empty value, and anything
    /// non-hex answers nil so the caller keeps the original string.
    static func decode(_ s: String) -> Data? {
        let chars = Array(s.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let high = value(chars[i]), let low = value(chars[i + 1]) else { return nil }
            out.append(high << 4 | low)
            i += 2
        }
        return out
    }

    private static func hexDigit(_ v: UInt8) -> UInt8 {
        v < 10 ? UInt8(ascii: "0") + v : UInt8(ascii: "A") + v - 10
    }

    private static func value(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
