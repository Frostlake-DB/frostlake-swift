import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Open a connection and verify the server is reachable (GET /api/health).
public func connect(_ dsn: String) async throws -> FrostlakeConnection {
    let connection = try FrostlakeConnection(dsn: dsn)
    try await connection.ping()
    return connection
}

/// One engine session over the HTTP protocol. Statements are serialized per
/// connection, in call order: the sessionId is only learned from the first
/// response, so concurrent round trips would each get their own server session
/// and split the connection's state.
public actor FrostlakeConnection {
    public let config: FrostlakeConfig
    private let executeURL: URL
    private let healthURL: URL
    private var sessionIdValue: String?
    private var autoCommitValue = true
    private var closedValue = false
    /// USE statements from the DSN, run before the first statement. A failed
    /// USE stays queued, so every later statement keeps failing instead of
    /// silently running against the server's default database.
    private var pendingUse: [String]
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(dsn: String) throws {
        try self.init(config: FrostlakeConfig(dsn: dsn))
    }

    public init(config: FrostlakeConfig) throws {
        self.config = config
        guard let execute = URL(string: config.baseUrl + "/api/execute"),
              let health = URL(string: config.baseUrl + "/api/health") else {
            throw FrostlakeError.invalidDSN(config.baseUrl)
        }
        executeURL = execute
        healthURL = health
        var use: [String] = []
        if let database = config.database {
            use.append("USE DATABASE \(quoteIdentifier(database))")
        }
        if let schema = config.schema {
            use.append("USE SCHEMA \(quoteIdentifier(schema))")
        }
        pendingUse = use
    }

    /// The server session id, learned from the first response.
    public var sessionId: String? { sessionIdValue }
    public var autoCommit: Bool { autoCommitValue }
    public var isClosed: Bool { closedValue }

    public func setAutoCommit(_ enabled: Bool) {
        autoCommitValue = enabled
    }

    public func ping() async throws {
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: URLRequest(url: healthURL))
        } catch {
            throw FrostlakeError.transport(
                "cannot reach server at \(config.baseUrl): \(describeTransportError(error))")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw FrostlakeError.unhealthy(status: status)
        }
    }

    /// Execute one statement (or several separated by `;` — each answers with
    /// its own entry in the result's resultSets). For DML the result's
    /// rowCount is the affected-row count.
    ///
    /// `multiStatementCount` says how many statements this call carries, 0 for
    /// any number; the engine refuses a call whose count differs, as the
    /// account does. It rides on this one request and outranks the session's
    /// MULTI_STATEMENT_COUNT for it without changing any session state, so
    /// there is nothing to put back and other statements on the connection are
    /// unaffected. Left out, nothing is sent and the session's value decides.
    public func execute(_ sql: String, _ binds: [FrostlakeBind] = [],
                        multiStatementCount: Int? = nil) async throws -> FrostlakeResult {
        guard !closedValue else { throw FrostlakeError.connectionClosed }
        let rendered = binds.isEmpty ? sql : try Substitution.substitute(sql, binds: binds)
        await acquire()
        defer { release() }
        // Each pending USE is one statement of its own, whatever this call declares.
        while let use = pendingUse.first {
            _ = try await roundTrip(use)
            pendingUse.removeFirst()
        }
        return ResultShaping.shape(
            try await roundTrip(rendered, multiStatementCount: multiStatementCount))
    }

    public func begin() async throws {
        autoCommitValue = false
        _ = try await execute("BEGIN")
    }

    public func commit() async throws {
        _ = try await execute("COMMIT")
        autoCommitValue = true
    }

    public func rollback() async throws {
        _ = try await execute("ROLLBACK")
        autoCommitValue = true
    }

    /// Mark the connection closed; later executes throw. (The protocol has no
    /// session-close call — server sessions expire on their own.)
    public func close() {
        closedValue = true
    }

    private func roundTrip(_ sql: String,
                           multiStatementCount: Int? = nil) async throws -> WireEnvelope {
        var request = URLRequest(url: executeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = JSONText.requestBody(
            sql: sql, sessionId: sessionIdValue, autoCommit: autoCommitValue,
            multiStatementCount: multiStatementCount)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FrostlakeError.transport("request failed: \(describeTransportError(error))")
        }
        // Failed statements answer with a non-2xx status AND the error payload
        // in the body, so the body decides; the status is only reported when
        // the body is unreadable.
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let root: JSONValue
        do {
            root = try JSONParser.parse(data)
        } catch {
            throw FrostlakeError.unreadableBody(status: status)
        }
        let envelope = WireEnvelope(root: root)
        if let sid = envelope.sessionId {
            sessionIdValue = sid
        }
        guard envelope.success else {
            throw FrostlakeError.sql(envelope.errorMessage ?? "statement failed")
        }
        return envelope
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private func describeTransportError(_ error: any Error) -> String {
    if let urlError = error as? URLError {
        return urlError.localizedDescription
    }
    return String(describing: error)
}
