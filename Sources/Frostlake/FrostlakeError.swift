import Foundation

/// Every error the driver throws. `sql` carries the engine's error message for
/// a statement the server rejected; the other cases are client-side.
public enum FrostlakeError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The DSN could not be parsed, or names an unsupported scheme.
    case invalidDSN(String)
    /// The server could not be reached, or the HTTP round trip itself failed.
    case transport(String)
    /// `/api/health` answered with a non-2xx status.
    case unhealthy(status: Int)
    /// The response body was not the JSON envelope the protocol promises.
    case unreadableBody(status: Int)
    /// The statement failed; the payload is the engine's error message.
    case sql(String)
    /// Bind values do not line up with the `?` placeholders, or a value cannot
    /// be rendered as a SQL literal.
    case binds(String)
    /// `execute` was called after `close`.
    case connectionClosed
    /// The engine no longer held the connection's session (it expired, was
    /// released, or the server restarted), and the statement did not run. A lost
    /// session is replaced on its own when nothing went with it; this is thrown
    /// when it held an open transaction or context set up on it (USE, SET, ALTER
    /// SESSION, a temporary object), since re-running the statement would put it
    /// somewhere its author did not intend. The connection stays usable: the next
    /// statement starts a fresh session on the DSN's scope.
    case sessionLost(String)

    public var description: String {
        switch self {
        case .invalidDSN(let dsn): return "invalid DSN: \(dsn)"
        case .transport(let message): return message
        case .unhealthy(let status): return "server unhealthy: HTTP \(status)"
        case .unreadableBody(let status): return "HTTP \(status) with unreadable body"
        case .sql(let message): return message
        case .binds(let message): return message
        case .connectionClosed: return "connection is closed"
        case .sessionLost(let message): return message
        }
    }
}
