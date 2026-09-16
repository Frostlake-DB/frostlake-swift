import Foundation

/// Connection endpoint parsed from a DSN of the form
/// `frostlake://host[:port]/[database][?schema=name]` — or `http://…`, which
/// keeps URL port semantics. `frostlake://` without an explicit port means the
/// server default, 18082.
public struct FrostlakeConfig: Sendable, Equatable {
    /// "http://host[:port]", no trailing slash.
    public var baseUrl: String
    public var database: String?
    public var schema: String?

    public init(baseUrl: String, database: String? = nil, schema: String? = nil) {
        self.baseUrl = baseUrl
        self.database = database
        self.schema = schema
    }

    public init(dsn: String) throws {
        guard let parts = URLComponents(string: dsn), let scheme = parts.scheme else {
            throw FrostlakeError.invalidDSN(dsn)
        }
        guard scheme == "frostlake" || scheme == "http" else {
            throw FrostlakeError.invalidDSN("DSN must start with frostlake:// or http://")
        }
        guard var host = parts.host, !host.isEmpty else {
            throw FrostlakeError.invalidDSN("DSN is missing host[:port]")
        }
        if host.contains(":") {   // IPv6 literal
            host = "[\(host)]"
        }
        if let port = parts.port {
            baseUrl = "http://\(host):\(port)"
        } else if scheme == "frostlake" {
            baseUrl = "http://\(host):18082"
        } else {
            baseUrl = "http://\(host)"
        }
        let db = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        database = db.isEmpty ? nil : db
        schema = parts.queryItems?.first { $0.name == "schema" }?.value
    }
}

/// Render `name` the way the DSN's database/schema reach a USE statement: a
/// valid unquoted identifier passes through bare in either case — the engine
/// uppercases it, like Snowflake and like the JDBC driver's URL handling.
/// Anything else is quoted, preserving exact case.
func quoteIdentifier(_ name: String) -> String {
    var bare = !name.isEmpty
    var first = true
    for scalar in name.unicodeScalars {
        let alpha = (scalar >= "A" && scalar <= "Z") || (scalar >= "a" && scalar <= "z") || scalar == "_"
        let tail = alpha || (scalar >= "0" && scalar <= "9") || scalar == "$"
        if first ? !alpha : !tail {
            bare = false
            break
        }
        first = false
    }
    return bare ? name : "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
}
