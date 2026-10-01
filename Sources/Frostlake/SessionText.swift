/// What a statement does to the session's transaction.
enum TransactionEffect: Sendable, Equatable {
    /// `BEGIN` on its own (or with TRANSACTION, WORK or NAME), or START TRANSACTION.
    case begins
    /// COMMIT or ROLLBACK.
    case ends
    /// Anything else.
    case none
}

/// How a request's statements change the engine session. It reads SQL with the
/// scanner bind substitution uses, so the two cannot disagree about what is code
/// and what sits inside a literal, a quoted identifier, a comment or a $$ body.
enum SessionText {

    /// The request split on its top-level semicolons; blank pieces are dropped.
    /// A scripting block is split along with everything else, which only makes
    /// the checks below more willing to flag a request — the safe direction.
    static func statements(_ sql: String) -> [String] {
        let chars = Array(sql)
        var pieces: [String] = []
        var start = 0
        var i = 0
        while i < chars.count {
            if let past = skipNonCode(chars, at: i) {
                i = past
            } else if chars[i] == ";" {
                pieces.append(String(chars[start..<i]))
                start = i + 1
                i += 1
            } else {
                i += 1
            }
        }
        pieces.append(String(chars[start..<chars.count]))
        var out: [String] = []
        for piece in pieces where !piece.allSatisfy(\.isWhitespace) {
            out.append(piece)
        }
        return out
    }

    /// Whether a statement leaves behind state a fresh session would not have:
    /// a moved scope (USE, or CREATE or DROP of a DATABASE or SCHEMA), a session
    /// variable or setting (SET, UNSET, ALTER SESSION), or a temporary object.
    /// CREATE TABLE and its kind leave the session as it was.
    static func touchesSession(_ statement: String) -> Bool {
        let words = leadingWords(statement, limit: 16)
        guard let verb = words.first else { return false }
        switch verb {
        case "USE", "SET", "UNSET":
            return true
        case "ALTER":
            return firstNonModifier(words.dropFirst()) == "SESSION"
        case "CREATE", "DROP":
            let kind = firstNonModifier(words.dropFirst())
            if kind == "DATABASE" || kind == "SCHEMA" { return true }
            guard verb == "CREATE" else { return false }
            for word in words.dropFirst() {
                if temporary.contains(word) { return true }
                if !modifiers.contains(word) { return false }
            }
            return false
        default:
            return false
        }
    }

    /// Whether a statement opens or ends a transaction. `BEGIN` followed by a
    /// statement opens a scripting block instead, which is no transaction.
    static func transactionEffect(_ statement: String) -> TransactionEffect {
        let words = leadingWords(statement, limit: 2)
        switch words.first {
        case "BEGIN":
            if words.count == 1 { return .begins }
            return ["TRANSACTION", "WORK", "NAME"].contains(words[1]) ? .begins : .none
        case "START":
            return words.count == 2 && words[1] == "TRANSACTION" ? .begins : .none
        case "COMMIT", "ROLLBACK":
            return .ends
        default:
            return .none
        }
    }

    /// Up to `limit` leading words of a statement, upper-cased, skipping
    /// whitespace and comments and stopping at the first thing that is not a word.
    static func leadingWords(_ statement: String, limit: Int) -> [String] {
        let chars = Array(statement)
        var words: [String] = []
        var i = 0
        while words.count < limit, i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c.isWhitespace {
                i += 1
            } else if (c == "-" && next == "-") || (c == "/" && next == "/") {
                i = Substitution.skipLine(chars, from: i)
            } else if c == "/" && next == "*" {
                i = Substitution.find(chars, "*", "/", from: i + 2).map { $0 + 2 } ?? chars.count
            } else if isWordChar(c) {
                let start = i
                while i < chars.count, isWordChar(chars[i]) { i += 1 }
                words.append(String(chars[start..<i]).uppercased())
            } else {
                break
            }
        }
        return words
    }

    /// The words that may sit between CREATE/DROP/ALTER and the kind of object named.
    private static let modifiers: Set<String> = [
        "OR", "REPLACE", "TRANSIENT", "TEMPORARY", "TEMP", "VOLATILE", "LOCAL", "GLOBAL",
        "SECURE", "IF", "NOT", "EXISTS", "PUBLIC", "PRIVATE", "ICEBERG", "DYNAMIC", "HYBRID",
        "EVENT", "RECURSIVE", "MATERIALIZED", "EXTERNAL",
    ]

    private static let temporary: Set<String> = ["TEMPORARY", "TEMP", "VOLATILE"]

    private static func firstNonModifier(_ words: ArraySlice<String>) -> String? {
        for word in words where !modifiers.contains(word) {
            return word
        }
        return nil
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c == "_" || c == "$" || c.isLetter || c.isNumber
    }

    /// Index just past the literal, quoted identifier, comment or $$ body that
    /// starts at `i`, or nil when `i` is code — the constructs bind substitution
    /// steps over.
    private static func skipNonCode(_ chars: [Character], at i: Int) -> Int? {
        let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
        switch chars[i] {
        case "'":
            return Substitution.skipString(chars, from: i)
        case "\"":
            return Substitution.skipQuoted(chars, from: i)
        case "-" where next == "-", "/" where next == "/":
            return Substitution.skipLine(chars, from: i)
        case "/" where next == "*":
            return Substitution.find(chars, "*", "/", from: i + 2).map { $0 + 2 } ?? chars.count
        case "$" where next == "$":
            return Substitution.find(chars, "$", "$", from: i + 2).map { $0 + 2 } ?? chars.count
        default:
            return nil
        }
    }
}
