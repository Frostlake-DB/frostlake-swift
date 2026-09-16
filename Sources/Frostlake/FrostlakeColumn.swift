/// Result-set column metadata as the wire reports it. `dataType` is the
/// engine's type name ("NUMBER", "VARCHAR", "TIMESTAMP_NTZ", …); for NUMBER,
/// `scale` decides whether cells decode as .int (scale 0) or .decimal.
public struct FrostlakeColumn: Sendable, Equatable {
    public let name: String
    public let dataType: String
    public let nullable: Bool
    public let precision: Int
    public let scale: Int

    /// The column's declared width — characters for text, bytes for binary,
    /// and the type's maximum for an unbounded one. The account reports this
    /// same number as both the column's precision and its display size.
    ///
    /// `nil` for every other type, and for a server that predates the field:
    /// unknown, never a width of 0.
    public let length: Int?

    public init(
        name: String,
        dataType: String,
        nullable: Bool,
        precision: Int,
        scale: Int,
        length: Int? = nil
    ) {
        self.name = name
        self.dataType = dataType
        self.nullable = nullable
        self.precision = precision
        self.scale = scale
        self.length = length
    }
}
