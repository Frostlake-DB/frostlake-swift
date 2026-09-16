import Foundation

/// One cell of a result row, decoded per its column's declared type: integral
/// NUMBER as .int (the engine stores integers 64-bit, so this is lossless),
/// scaled NUMBER as .decimal — exact to all 38 digits — FLOAT as .double,
/// BOOLEAN as .bool, BINARY as .binary, and temporals / text / ARRAY / OBJECT /
/// VARIANT as .string carrying the wire text. The typed accessors return nil
/// rather than guessing across kinds; the widening ones (decimalValue,
/// doubleValue) accept any numeric case.
public enum FrostlakeValue: Sendable, Equatable, CustomStringConvertible {
    case null
    case int(Int64)
    case decimal(Decimal)
    case double(Double)
    case bool(Bool)
    case string(String)
    case binary(Data)

    public var isNull: Bool { self == .null }

    public var intValue: Int64? {
        switch self {
        case .int(let v): return v
        case .decimal(let v): return Int64("\(v)")   // exact integral decimals only
        case .double(let v): return v == v.rounded() ? Int64(exactly: v.rounded()) : nil
        default: return nil
        }
    }

    public var decimalValue: Decimal? {
        switch self {
        case .int(let v): return Decimal(v)
        case .decimal(let v): return v
        case .double(let v): return Decimal(v)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .decimal(let v): return NSDecimalNumber(decimal: v).doubleValue
        case .double(let v): return v
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var binaryValue: Data? {
        if case .binary(let v) = self { return v }
        return nil
    }

    /// A DATE (or timestamp) cell's calendar date, placed at UTC midnight.
    public var dateValue: Date? {
        if case .string(let v) = self { return TemporalText.parseDate(v) }
        return nil
    }

    /// A TIMESTAMP_* cell's wall-clock reading placed at UTC — the same local
    /// part the JDBC driver's getTimestamp reports (a trailing zone offset on
    /// the wire text is dropped, not applied).
    public var timestampValue: Date? {
        if case .string(let v) = self { return TemporalText.parseTimestamp(v) }
        return nil
    }

    /// A TIME cell as seconds since midnight.
    public var timeValue: TimeInterval? {
        if case .string(let v) = self { return TemporalText.parseTime(v) }
        return nil
    }

    public var description: String {
        switch self {
        case .null: return "NULL"
        case .int(let v): return "\(v)"
        case .decimal(let v): return "\(v)"
        case .double(let v): return "\(v)"
        case .bool(let v): return "\(v)"
        case .string(let v): return v
        case .binary(let v): return HexText.encode(v)
        }
    }
}
