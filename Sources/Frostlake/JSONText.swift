import Foundation

/// JSON writing: the request body for /api/execute, and a compact rendering
/// used when a structured cell unexpectedly arrives as real JSON rather than
/// the engine's text form.
enum JSONText {

    /// Escape `s` for inclusion inside a JSON string literal (no quotes added).
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// `multiStatementCount` is left out of the body entirely when nil: a
    /// request without the field is the one the server has always been sent,
    /// and the session's MULTI_STATEMENT_COUNT decides for it.
    static func requestBody(sql: String, sessionId: String?, autoCommit: Bool,
                            multiStatementCount: Int? = nil) -> Data {
        var json = "{\"sql\":\"\(escape(sql))\",\"autoCommit\":\(autoCommit)"
        if let sessionId {
            json += ",\"sessionId\":\"\(escape(sessionId))\""
        }
        if let multiStatementCount {
            json += ",\"multiStatementCount\":\(multiStatementCount)"
        }
        json += "}"
        return Data(json.utf8)
    }

    /// Compact JSON text of `value`, object keys sorted for determinism.
    static func render(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let raw): return raw
        case .string(let s): return "\"\(escape(s))\""
        case .array(let items):
            var parts: [String] = []
            parts.reserveCapacity(items.count)
            for item in items { parts.append(render(item)) }
            return "[" + parts.joined(separator: ",") + "]"
        case .object(let fields):
            var parts: [String] = []
            parts.reserveCapacity(fields.count)
            for key in fields.keys.sorted() {
                parts.append("\"\(escape(key))\":\(render(fields[key]!))")
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
    }
}
