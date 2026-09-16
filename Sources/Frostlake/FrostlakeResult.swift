/// One result set: the columns and decoded rows exactly as the statement
/// answered them — for DML, the engine's count row ("number of rows inserted"
/// …) — plus `updateCount`, which says whether the statement was DML at all
/// (see ResultShaping).
public struct FrostlakeResultSet: Sendable {
    public let columns: [FrostlakeColumn]
    public let rows: [FrostlakeRow]

    /// The affected-row count for DML; nil for anything else, never a
    /// stand-in 0.
    public let updateCount: Int64?

    public init(columns: [FrostlakeColumn], rows: [FrostlakeRow], updateCount: Int64? = nil) {
        self.columns = columns
        self.rows = rows
        self.updateCount = updateCount
    }

    /// The affected-row count for DML, the number of rows otherwise.
    public var rowCount: Int {
        updateCount.map { Int($0) } ?? rows.count
    }
}

/// The result of one execute: every statement's result set (multi-statement
/// SQL answers with several), with the first surfaced as columns / rows /
/// rowCount / updateCount for the common single-statement call.
public struct FrostlakeResult: Sendable {
    public let resultSets: [FrostlakeResultSet]
    public let executionTimeMs: Int64

    public init(resultSets: [FrostlakeResultSet], executionTimeMs: Int64) {
        self.resultSets = resultSets
        self.executionTimeMs = executionTimeMs
    }

    public var columns: [FrostlakeColumn] { resultSets.first?.columns ?? [] }
    public var rows: [FrostlakeRow] { resultSets.first?.rows ?? [] }
    public var rowCount: Int { resultSets.first?.rowCount ?? 0 }
    public var updateCount: Int64? { resultSets.first?.updateCount }
}
