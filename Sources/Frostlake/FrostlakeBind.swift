import Foundation

/// A value bound to a `?` placeholder. Parameters are inlined client-side —
/// the protocol has no server-side binding — with the same literal forms as
/// Frostlake's JDBC driver: strings escape both backslash and quote (the
/// lexer honors backslash escapes, so doubling only the quote would let a
/// trailing backslash break out of the literal), Data becomes X'…', Date
/// becomes an ISO timestamp cast to TIMESTAMP_NTZ (or a DATE via .date).
/// Literal conformances let call sites write [1, "x", 3.14, true, nil].
public enum FrostlakeBind: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case decimal(Decimal)
    case string(String)
    case timestamp(Date)
    case date(Date)
    case binary(Data)
    case array([FrostlakeBind])

    func literal() throws -> String {
        switch self {
        case .null:
            return "NULL"
        case .bool(let v):
            return v ? "true" : "false"
        case .int(let v):
            return "\(v)"
        case .double(let v):
            guard v.isFinite else { throw FrostlakeError.binds("non-finite number \(v)") }
            return "\(v)"
        case .decimal(let v):
            return "\(v)"
        case .string(let v):
            let escaped = v.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "''")
            return "'\(escaped)'"
        case .timestamp(let v):
            return "'\(TemporalText.formatTimestamp(v))'::TIMESTAMP_NTZ"
        case .date(let v):
            return "'\(TemporalText.formatDate(v))'::DATE"
        case .binary(let v):
            return "X'\(HexText.encode(v))'"
        case .array(let items):
            var parts: [String] = []
            parts.reserveCapacity(items.count)
            for item in items {
                parts.append(try item.literal())
            }
            return "[" + parts.joined(separator: ", ") + "]"
        }
    }
}

extension FrostlakeBind: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension FrostlakeBind: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension FrostlakeBind: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension FrostlakeBind: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension FrostlakeBind: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension FrostlakeBind: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: FrostlakeBind...) { self = .array(elements) }
}
