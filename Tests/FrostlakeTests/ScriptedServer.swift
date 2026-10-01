import Foundation
@testable import Frostlake
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One request the driver sent, with its JSON body read back.
struct SentRequest: Sendable {
    let method: String
    let path: String
    /// The request's JSON object; empty for a request without a body.
    let body: [String: JSONValue]

    var sql: String? { body["sql"]?.stringOrNil }
    var sessionId: String? { body["sessionId"]?.stringOrNil }
    /// Whether the body carries the field at all, whatever its value.
    var hasRequireSession: Bool { body["requireSession"] != nil }
    var requireSession: Bool? { body["requireSession"]?.boolOrNil }
    var autoCommit: Bool? { body["autoCommit"]?.boolOrNil }
}

/// A stand-in engine on a real loopback socket, answering from a script and
/// recording what it was sent, so a test can say exactly which round trips a
/// scenario makes — through the driver's own HTTP transport.
///
/// `GET /api/health` is answered as an engine answers it, unscripted; every
/// other request takes the next scripted step. A request with nothing scripted
/// for it is answered with HTTP 500 and kept in `unscripted` for the test to
/// fail on.
final class ScriptedServer: @unchecked Sendable {
    private enum Step {
        case reply(status: Int, body: String)
        case hang
        case drop
    }

    private let lock = NSLock()
    private var script: [Step] = []
    private var sentRequests: [SentRequest] = []
    private var unscriptedRequests: [SentRequest] = []
    /// Sockets of requests held open by `hang()`, closed by `stop()`.
    private var held: [Int32] = []
    private let listener: Int32
    let port: Int

    init() throws {
        #if canImport(Glibc)
        let stream = Int32(SOCK_STREAM.rawValue)
        #else
        let stream = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, stream, 0)
        guard fd >= 0 else { throw FrostlakeError.transport("socket() failed") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw FrostlakeError.transport("cannot listen on a loopback port")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        listener = fd
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// A DSN for this stand-in; `suffix` carries a path and a query string.
    func dsn(_ suffix: String = "") -> String {
        "frostlake://127.0.0.1:\(port)\(suffix)"
    }

    /// The next request is answered with `body` and `status`.
    func reply(_ body: String, status: Int = 200) {
        lock.withLock { script.append(.reply(status: status, body: body)) }
    }

    /// The next request is held open and never answered.
    func hang() {
        lock.withLock { script.append(.hang) }
    }

    /// The next request's socket is closed without an answer.
    func drop() {
        lock.withLock { script.append(.drop) }
    }

    /// Every request but the health check, in arrival order.
    var sent: [SentRequest] { lock.withLock { sentRequests } }

    /// Requests that arrived with nothing scripted for them.
    var unscripted: [SentRequest] { lock.withLock { unscriptedRequests } }

    /// How many scripted steps no request has taken yet.
    var pending: Int { lock.withLock { script.count } }

    /// Every `POST /api/execute`, in order.
    var executes: [SentRequest] { sent.filter { $0.path == "/api/execute" } }

    /// The SQL of every `POST /api/execute`, in order.
    var statements: [String?] { executes.map(\.sql) }

    /// Stops listening and closes every socket still held open.
    func stop() {
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
        let open = lock.withLock {
            let sockets = held
            held = []
            return sockets
        }
        for socket in open {
            close(socket)
        }
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { return }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ socket: Int32) {
        guard let (method, path, body) = readRequest(socket) else {
            close(socket)
            return
        }
        if path == "/api/health" {
            respond(socket, status: 200, body: "{\"status\":\"healthy\",\"activeSessions\":0}")
            close(socket)
            return
        }
        let parsed = (try? JSONParser.parse(body))?.objectOrNil ?? [:]
        let record = SentRequest(method: method, path: path, body: parsed)
        let step: Step? = lock.withLock {
            sentRequests.append(record)
            if script.isEmpty {
                unscriptedRequests.append(record)
                return nil
            }
            return script.removeFirst()
        }
        switch step {
        case nil:
            respond(socket, status: 500, body: "{\"success\":false,\"errorMessage\":\"unscripted request\"}")
            close(socket)
        case .reply(let status, let text):
            respond(socket, status: status, body: text)
            close(socket)
        case .hang:
            lock.withLock { held.append(socket) }
        case .drop:
            close(socket)
        }
    }

    /// The request line and body of one HTTP request, or nil when the client
    /// went away before sending a whole one.
    private func readRequest(_ socket: Int32) -> (String, String, Data)? {
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let count = recv(socket, &buffer, buffer.count, 0)
            if count <= 0 { return nil }
            received.append(contentsOf: buffer[0..<count])
            headerEnd = received.range(of: separator)
        }
        guard let end = headerEnd,
              let head = String(data: received[received.startIndex..<end.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        var length = 0
        var expectsContinue = false
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { length = Int(value) ?? 0 }
            if name == "expect" && value.lowercased() == "100-continue" { expectsContinue = true }
        }
        if expectsContinue {
            write(socket, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        var body = Data(received[end.upperBound...])
        while body.count < length {
            let count = recv(socket, &buffer, buffer.count, 0)
            if count <= 0 { return nil }
            body.append(contentsOf: buffer[0..<count])
        }
        return (String(requestLine[0]), String(requestLine[1]), body)
    }

    private func respond(_ socket: Int32, status: Int, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(payload.count)\r\n"
            + "Connection: close\r\n\r\n"
        write(socket, Data(head.utf8) + payload)
    }

    private func write(_ socket: Int32, _ data: Data) {
        #if canImport(Glibc)
        let flags = Int32(MSG_NOSIGNAL)
        #else
        let flags: Int32 = 0
        #endif
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = send(socket, raw.baseAddress! + offset, raw.count - offset, flags)
                if written <= 0 { return }
                offset += written
            }
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Status"
        }
    }
}

/// A one-row result set holding a status line, as DDL and USE answer.
func statusSet(_ text: String) -> String {
    #"{"columns":[{"dataType":"VARCHAR","name":"status","nullable":false,"precision":0,"scale":0}],"#
        + #""rowCount":1,"rows":[[""# + text + #""]],"updateCount":-1}"#
}

/// A one-row, one-column NUMBER result set.
func numberSet(_ name: String, _ value: Int) -> String {
    #"{"columns":[{"dataType":"NUMBER","name":""# + name
        + #"","nullable":false,"precision":38,"scale":0}],"rowCount":1,"rows":[["#
        + String(value) + #"]],"updateCount":-1}"#
}

/// An answer from an engine that reports `newSession` (0.1.0 and later).
func answer(_ sessionId: String, started: Bool = false, _ sets: [String] = []) -> String {
    #"{"errorMessage":null,"executionTimeMs":1,"newSession":"# + (started ? "true" : "false")
        + #","resultSets":["# + sets.joined(separator: ",") + #"],"sessionId":""# + sessionId
        + #"","success":true}"#
}

/// An answer from an engine that predates `newSession` (0.0.7).
func legacyAnswer(_ sessionId: String, _ sets: [String] = []) -> String {
    #"{"errorMessage":null,"executionTimeMs":1,"resultSets":["# + sets.joined(separator: ",")
        + #"],"sessionId":""# + sessionId + #"","success":true}"#
}

/// A statement the engine refused, in the session it ran in.
func refused(_ sessionId: String, _ message: String) -> String {
    #"{"errorMessage":""# + JSONText.escape(message)
        + #"","executionTimeMs":0,"newSession":false,"resultSets":[],"sessionId":""# + sessionId
        + #"","success":false}"#
}

/// The 404 body a request that requires its session gets when it is gone.
func sessionGone(_ sessionId: String) -> String {
    #"{"errorMessage":"Session '"# + sessionId
        + #"' does not exist or has expired.","executionTimeMs":0,"newSession":false,"#
        + #""resultSets":[],"sessionId":null,"success":false}"#
}

/// What `DELETE /api/sessions/{id}` answers for a live session.
let released =
    #"{"errorMessage":null,"executionTimeMs":0,"newSession":false,"resultSets":[],"sessionId":null,"success":true}"#
