import Foundation

/// Wire JSON → FrostlakeValue, decided by the column's declared type. The
/// engine stores integral NUMBER 64-bit (so .int is lossless), scaled NUMBER
/// as exact decimals — carried here via the raw number text — and BINARY
/// crosses as bare hex. Structured cells (ARRAY / OBJECT / VARIANT) arrive as
/// Snowflake's text rendering and pass through as .string; that text is not
/// always parseable JSON (a SQL NULL array element renders as `undefined`).
enum ValueDecoding {

    static func decode(_ wire: JSONValue, column: FrostlakeColumn) -> FrostlakeValue {
        switch wire {
        case .null:
            return .null
        case .bool(let b):
            return .bool(b)
        case .string(let s):
            let t = column.dataType.uppercased()
            if t.contains("BINARY") || t.contains("BYTES"), let data = HexText.decode(s) {
                return .binary(data)
            }
            return .string(s)
        case .number(let raw):
            return decodeNumber(raw, column: column)
        case .array, .object:
            // The engine sends structured cells as text today; render defensively
            // if that ever changes rather than dropping the value.
            return .string(JSONText.render(wire))
        }
    }

    private static func decodeNumber(_ raw: String, column: FrostlakeColumn) -> FrostlakeValue {
        let t = column.dataType.uppercased()
        if t.contains("DOUBLE") || t.contains("REAL") || t.contains("FLOAT") {
            return .double(Double(raw) ?? 0)
        }
        if column.scale == 0, let i = Int64(raw) {
            return .int(i)
        }
        if let d = Decimal(string: raw, locale: nil) {
            return .decimal(d)
        }
        return .double(Double(raw) ?? 0)
    }
}
