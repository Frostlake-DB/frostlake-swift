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
///
/// The engine can lose the session: it expires after 30 idle minutes, and a
/// restart ends them all. A statement that finds its session gone is sent once
/// more on a fresh session with the DSN's scope, unless the lost session held an
/// open transaction or context of the caller's own — then it throws
/// `FrostlakeError.sessionLost` instead. `close()` releases the session.
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
    /// The DSN's scope as USE statements: what a fresh session gets first.
    private let scope: [String]
    /// Bumped whenever the scope is queued afresh, so a USE whose answer
    /// restarted the queue does not take the head of the new one with it.
    private var scopeGeneration = 0
    /// Whether the engine reports `newSession` — which arrived together with
    /// `requireSession` and `DELETE /api/sessions/{id}` — or nil until the first
    /// answer that names a session settles it.
    private var tracksSessions: Bool?
    /// Set once a statement left state behind that a fresh session would not
    /// have (see `SessionText.touchesSession`).
    private var dirty = false
    /// Whether a transaction is open: set by a BEGIN or START TRANSACTION that
    /// succeeded, cleared by a COMMIT or ROLLBACK, however each was sent.
    private var inTransaction = false
    /// The autocommit mode the session last ran a statement under. With it off,
    /// the session may hold a transaction no BEGIN opened.
    private var sessionAutoCommit = true
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
        scope = use
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
        let envelope = try await statement(rendered, multiStatementCount: multiStatementCount)
        track(sql)
        return ResultShaping.shape(envelope)
    }

    public func begin() async throws {
        // BEGIN goes out with autocommit off, the mode the transaction runs in,
        // but the connection takes that mode on only once BEGIN has succeeded:
        // after a BEGIN that failed, statements sent with autocommit off would
        // run in a transaction nobody commits, rolled back unseen when the
        // session ends.
        try await transactionStatement("BEGIN", sentWith: false, thenAutoCommit: false)
    }

    public func commit() async throws {
        try await transactionStatement("COMMIT", thenAutoCommit: true)
    }

    public func rollback() async throws {
        try await transactionStatement("ROLLBACK", thenAutoCommit: true)
    }

    /// Runs BEGIN, COMMIT or ROLLBACK, and puts the connection in the autocommit
    /// mode `thenAutoCommit` only once it has succeeded — within the same turn
    /// on the session, so a statement queued behind it never runs under a mode
    /// the statement did not establish. `sentWith` overrides the mode for this
    /// one request; nil sends the connection's own.
    private func transactionStatement(_ sql: String, sentWith: Bool? = nil,
                                      thenAutoCommit: Bool) async throws {
        guard !closedValue else { throw FrostlakeError.connectionClosed }
        await acquire()
        defer { release() }
        _ = try await statement(sql, multiStatementCount: nil, autoCommit: sentWith)
        track(sql)
        autoCommitValue = thenAutoCommit
    }

    /// Mark the connection closed, so later executes throw, and release its
    /// engine session: one `DELETE /api/sessions/{id}`, which also rolls back a
    /// transaction left open on it. A statement already running finishes first.
    ///
    /// The release is a courtesy. It waits five seconds at most, and a release
    /// that fails or never answers is not an error — the engine expires the
    /// session on its own. An engine before 0.1.0 has no such endpoint and is sent
    /// nothing. Closing again does nothing.
    public func close() async {
        guard !closedValue else { return }
        closedValue = true
        await acquire()
        defer { release() }
        await releaseSession()
    }

    /// How long `close()` waits for the engine to release the session.
    private static let releaseTimeout: TimeInterval = 5

    private func releaseSession() async {
        let id = sessionIdValue
        sessionIdValue = nil
        inTransaction = false
        guard let id, tracksSessions == true else { return }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: config.baseUrl + "/api/sessions/" + escaped) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = Self.releaseTimeout
        // Whatever becomes of it, the connection is closed: a session the engine
        // did not release expires on its own.
        _ = try? await URLSession.shared.data(for: request)
    }

    /// The pending DSN scope, then `sql`, replacing a session the engine no
    /// longer holds.
    ///
    /// The engine answers 404 to a request that requires a session it does not
    /// have, and runs nothing. When the lost session held nothing a fresh one
    /// could not reproduce, the DSN's scope goes onto a fresh session and the
    /// statement is sent once more; otherwise `loseSession` throws.
    private func statement(_ sql: String, multiStatementCount: Int?,
                           autoCommit: Bool? = nil) async throws -> WireEnvelope {
        if let answer = try await unit(sql, multiStatementCount: multiStatementCount,
                                       autoCommit: autoCommit) {
            return answer
        }
        try loseSession()
        if let answer = try await unit(sql, multiStatementCount: multiStatementCount,
                                       autoCommit: autoCommit) {
            return answer
        }
        sessionIdValue = nil
        startOver()
        throw FrostlakeError.sessionLost("the engine refused a session it had just started")
    }

    /// The pending USE statements, then `sql`: nil when the engine refused the
    /// session as unknown on any of them, so that neither that request nor
    /// anything after it ran. `autoCommit` overrides the mode for `sql` alone;
    /// the USE statements go out in the connection's own.
    private func unit(_ sql: String, multiStatementCount: Int?,
                      autoCommit: Bool?) async throws -> WireEnvelope? {
        // Each pending USE is one statement of its own, whatever this call declares.
        while let use = pendingUse.first {
            let generation = scopeGeneration
            guard try await roundTrip(use) != nil else { return nil }
            if generation == scopeGeneration {
                pendingUse.removeFirst()
            }
        }
        return try await roundTrip(sql, multiStatementCount: multiStatementCount,
                                   autoCommit: autoCommit)
    }

    /// The engine no longer holds the session — it expired, was released, or the
    /// server restarted — and nothing ran. The next request starts a fresh
    /// session on the DSN's scope. With an open transaction or a moved context
    /// gone with the old one, re-running the statement would put it somewhere its
    /// author did not intend, so that is refused here rather than done.
    private func loseSession() throws {
        let hadTransaction = inTransaction || !sessionAutoCommit
        let hadContext = dirty
        sessionIdValue = nil
        startOver()
        if hadTransaction {
            throw FrostlakeError.sessionLost(
                "the engine no longer holds this connection's session (it expired, was released, "
                    + "or the server restarted), so its open transaction is gone; the statement "
                    + "did not run")
        }
        if hadContext {
            throw FrostlakeError.sessionLost(
                "the engine no longer holds this connection's session (it expired, was released, "
                    + "or the server restarted), and the context set up on it (USE, SET, ALTER "
                    + "SESSION or a temporary object) went with it, so the statement was not "
                    + "re-run; the next statement starts a fresh session on the connection's scope")
        }
    }

    /// Forgets what the session held: the one the next statement meets is fresh,
    /// and gets the DSN's scope first.
    private func startOver() {
        dirty = false
        inTransaction = false
        sessionAutoCommit = true
        pendingUse = scope
        scopeGeneration += 1
    }

    /// Follows what a statement that succeeded did to the session.
    private func track(_ sql: String) {
        for statement in SessionText.statements(sql) {
            if SessionText.touchesSession(statement) {
                dirty = true
            }
            switch SessionText.transactionEffect(statement) {
            case .begins: inTransaction = true
            case .ends: inTransaction = false
            case .none: break
            }
        }
    }

    /// Keeps the session an answer names, and learns from it whether the engine
    /// tracks sessions: a `newSession` field, true or false, says it does.
    private func absorb(_ envelope: WireEnvelope, sentId: Bool) {
        guard let sid = envelope.sessionId else { return }
        sessionIdValue = sid
        if let started = envelope.newSession {
            tracksSessions = true
            // The engine ran the statement in a fresh session in place of ours:
            // what the old one held is gone, and the DSN's scope goes back on
            // before the next statement.
            if started && sentId {
                startOver()
            }
        } else if tracksSessions == nil {
            tracksSessions = false
        }
    }

    /// One POST /api/execute, with no recovery: the answer, or nil when the
    /// engine refused the session as unknown and ran nothing. `sentWith`
    /// overrides the connection's autocommit mode for this one request.
    private func roundTrip(_ sql: String, multiStatementCount: Int? = nil,
                           autoCommit sentWith: Bool? = nil) async throws -> WireEnvelope? {
        let sentId = sessionIdValue
        // Resume this session or refuse: without the flag, an engine that no
        // longer holds the session starts a fresh one under the same id, at its
        // default scope, and runs the statement there. Only an engine known to
        // read the flag is sent it; an older one's parser need not accept a field
        // it does not know.
        let requireSession = sentId != nil && tracksSessions == true
        let autoCommit = sentWith ?? autoCommitValue
        var request = URLRequest(url: executeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = JSONText.requestBody(
            sql: sql, sessionId: sentId, autoCommit: autoCommit,
            multiStatementCount: multiStatementCount, requireSession: requireSession)
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
        // The one answer that names no session for a request that required one:
        // the session is gone, and nothing ran.
        if status == 404 && requireSession && !envelope.success && envelope.sessionId == nil {
            return nil
        }
        absorb(envelope, sentId: sentId != nil)
        if envelope.sessionId != nil {
            sessionAutoCommit = autoCommit
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
