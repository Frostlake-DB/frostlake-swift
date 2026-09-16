/// Case-respecting column lookup shared by every row of a result set: exact
/// name first, then case-insensitive — unquoted identifiers are uppercase on
/// the server, so row["name"] finds a column named NAME. First occurrence wins
/// for duplicate names, either way.
final class ColumnLookup: Sendable {
    let byExact: [String: Int]
    let byUpper: [String: Int]

    init(columns: [FrostlakeColumn]) {
        var exact: [String: Int] = [:]
        var upper: [String: Int] = [:]
        for (i, column) in columns.enumerated() {
            if exact[column.name] == nil { exact[column.name] = i }
            let u = column.name.uppercased()
            if upper[u] == nil { upper[u] = i }
        }
        byExact = exact
        byUpper = upper
    }
}

/// One decoded result row. Cells are addressed by 0-based position or by
/// column name.
public struct FrostlakeRow: Sendable, Equatable {
    public let values: [FrostlakeValue]
    let lookup: ColumnLookup

    init(values: [FrostlakeValue], lookup: ColumnLookup) {
        self.values = values
        self.lookup = lookup
    }

    public var count: Int { values.count }

    public subscript(index: Int) -> FrostlakeValue {
        values[index]
    }

    public subscript(name: String) -> FrostlakeValue? {
        if let i = lookup.byExact[name] { return values[i] }
        if let i = lookup.byUpper[name.uppercased()] { return values[i] }
        return nil
    }

    public static func == (lhs: FrostlakeRow, rhs: FrostlakeRow) -> Bool {
        lhs.values == rhs.values
    }
}
