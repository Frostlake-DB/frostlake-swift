/// A parsed JSON value. Numbers keep their raw wire text so a NUMBER(38,18)
/// cell survives with every digit — routing them through Double would corrupt
/// anything beyond ~15 significant digits, and the engine really does put all
/// 38 on the wire.
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    var stringOrNil: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolOrNil: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var numberOrNil: String? {
        if case .number(let n) = self { return n }
        return nil
    }

    var arrayOrNil: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var objectOrNil: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var intOrNil: Int64? {
        if case .number(let n) = self { return Int64(n) }
        return nil
    }
}
