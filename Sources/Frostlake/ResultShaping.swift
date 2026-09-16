/// Envelope → public result. Every result set keeps its columns and rows; what
/// shaping decides is the update count — whether a statement was DML, and how
/// many rows it touched.
///
/// A server that sends `updateCount` decides that itself: its count for DML,
/// -1 for everything else — including a query whose column merely carries a
/// count's name, such as a `->>` chain reading an INSERT's status row.
///
/// An older server sends no such field, so the count row is recognized by
/// shape: a single row whose columns all carry the engine's exact count names
/// (an aliased look-alike such as "number of rows once" stays a query), summed.
/// "number of multi-joined rows updated" is recognized but, per Snowflake
/// semantics, not part of the affected-row count. Shape alone cannot tell such
/// a row from a query that renames its column to a count name exactly; only the
/// server's own count can.
enum ResultShaping {

    static let summedCountColumns: Set<String> = [
        "number of rows inserted",
        "number of rows updated",
        "number of rows deleted",
    ]

    static let countColumns: Set<String> =
        summedCountColumns.union(["number of multi-joined rows updated"])

    static func shape(_ envelope: WireEnvelope) -> FrostlakeResult {
        var sets: [FrostlakeResultSet] = []
        sets.reserveCapacity(envelope.resultSets.count)
        for rs in envelope.resultSets {
            sets.append(shapeOne(rs))
        }
        return FrostlakeResult(resultSets: sets, executionTimeMs: envelope.executionTimeMs)
    }

    static func shapeOne(_ rs: WireResultSet) -> FrostlakeResultSet {
        let lookup = ColumnLookup(columns: rs.columns)
        var rows: [FrostlakeRow] = []
        rows.reserveCapacity(rs.rows.count)
        for raw in rs.rows {
            var values: [FrostlakeValue] = []
            values.reserveCapacity(rs.columns.count)
            for (i, column) in rs.columns.enumerated() {
                values.append(i < raw.count ? ValueDecoding.decode(raw[i], column: column) : .null)
            }
            rows.append(FrostlakeRow(values: values, lookup: lookup))
        }
        let updateCount: Int64?
        if let reported = rs.updateCount {
            updateCount = reported >= 0 ? reported : nil
        } else {
            updateCount = countFromGrid(rs.columns, rows)
        }
        return FrostlakeResultSet(columns: rs.columns, rows: rows, updateCount: updateCount)
    }

    private static func countFromGrid(_ columns: [FrostlakeColumn], _ rows: [FrostlakeRow]) -> Int64? {
        guard rows.count == 1, !columns.isEmpty else { return nil }
        var total: Int64 = 0
        var anySummed = false
        for (i, column) in columns.enumerated() {
            let name = column.name.lowercased()
            guard countColumns.contains(name) else { return nil }
            if summedCountColumns.contains(name) {
                anySummed = true
                total += rows[0].values[i].intValue ?? 0
            }
        }
        return anySummed ? total : nil
    }
}
