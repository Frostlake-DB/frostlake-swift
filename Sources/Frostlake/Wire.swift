/// The /api/execute response envelope, decoded leniently: absent fields take
/// their zero values and `success` defaults to false, so a malformed body
/// surfaces as a failed statement rather than a crash.
struct WireEnvelope: Sendable {
    let success: Bool
    let errorMessage: String?
    let sessionId: String?
    let executionTimeMs: Int64
    let resultSets: [WireResultSet]

    init(root: JSONValue) {
        let fields = root.objectOrNil ?? [:]
        success = fields["success"]?.boolOrNil ?? false
        errorMessage = fields["errorMessage"]?.stringOrNil
        sessionId = fields["sessionId"]?.stringOrNil
        executionTimeMs = fields["executionTimeMs"]?.intOrNil ?? 0
        var sets: [WireResultSet] = []
        for entry in fields["resultSets"]?.arrayOrNil ?? [] {
            sets.append(WireResultSet(entry))
        }
        resultSets = sets
    }
}

struct WireResultSet: Sendable {
    let columns: [FrostlakeColumn]
    let rows: [[JSONValue]]
    /// The engine's own verdict on the statement: the affected-row count for
    /// DML, -1 for anything else. nil from a server that predates the field.
    let updateCount: Int64?

    init(_ value: JSONValue) {
        let fields = value.objectOrNil ?? [:]
        var cols: [FrostlakeColumn] = []
        for entry in fields["columns"]?.arrayOrNil ?? [] {
            let c = entry.objectOrNil ?? [:]
            // Only text and binary columns carry a length; absent stays absent
            // rather than collapsing to 0.
            var length: Int?
            if let declared = c["length"]?.intOrNil {
                length = Int(declared)
            }
            cols.append(FrostlakeColumn(
                name: c["name"]?.stringOrNil ?? "",
                dataType: c["dataType"]?.stringOrNil ?? "",
                nullable: c["nullable"]?.boolOrNil ?? true,
                precision: Int(c["precision"]?.intOrNil ?? 0),
                scale: Int(c["scale"]?.intOrNil ?? 0),
                length: length))
        }
        columns = cols
        var out: [[JSONValue]] = []
        for entry in fields["rows"]?.arrayOrNil ?? [] {
            out.append(entry.arrayOrNil ?? [])
        }
        rows = out
        updateCount = fields["updateCount"]?.intOrNil
    }

    init(columns: [FrostlakeColumn], rows: [[JSONValue]], updateCount: Int64? = nil) {
        self.columns = columns
        self.rows = rows
        self.updateCount = updateCount
    }
}
