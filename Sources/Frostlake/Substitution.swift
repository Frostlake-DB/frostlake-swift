/// Client-side `?` placeholder substitution. The scanner recognizes — and
/// copies through untouched — single-quoted strings (backslash escapes and ''
/// doubling), double-quoted identifiers, `--` and `//` line comments, /* */
/// block comments, and $$…$$ dollar-quoted strings (non-greedy to the next $$,
/// like the lexer's DOLLAR_QUOTED_STRING rule), so a ? inside any of them is
/// never a placeholder. Unterminated constructs run to the end of the text.
enum Substitution {

    static func substitute(_ sql: String, binds: [FrostlakeBind]) throws -> String {
        let chars = Array(sql)
        var out = ""
        out.reserveCapacity(chars.count + binds.count * 8)
        var next = 0
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "'" {
                let j = skipString(chars, from: i)
                out += String(chars[i..<j])
                i = j
            } else if ch == "\"" {
                let j = skipQuoted(chars, from: i)
                out += String(chars[i..<j])
                i = j
            } else if ch == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                let j = skipLine(chars, from: i)
                out += String(chars[i..<j])
                i = j
            } else if ch == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                let j = find(chars, "*", "/", from: i + 2).map { $0 + 2 } ?? chars.count
                out += String(chars[i..<j])
                i = j
            } else if ch == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                let j = skipLine(chars, from: i)
                out += String(chars[i..<j])
                i = j
            } else if ch == "$", i + 1 < chars.count, chars[i + 1] == "$" {
                let j = find(chars, "$", "$", from: i + 2).map { $0 + 2 } ?? chars.count
                out += String(chars[i..<j])
                i = j
            } else if ch == "?" {
                guard next < binds.count else {
                    throw FrostlakeError.binds("not enough bind values for placeholders")
                }
                out += try binds[next].literal()
                next += 1
                i += 1
            } else {
                out.append(ch)
                i += 1
            }
        }
        if next < binds.count {
            let plural = next == 1 ? "" : "s"
            throw FrostlakeError.binds(
                "too many bind values: \(binds.count) given, \(next) placeholder\(plural)")
        }
        return out
    }

    private static func skipString(_ s: [Character], from start: Int) -> Int {
        var j = start + 1
        while j < s.count {
            if s[j] == "\\" {
                j += 2   // backslash always escapes
            } else if s[j] == "'" {
                if j + 1 < s.count, s[j + 1] == "'" { j += 2 } else { return j + 1 }
            } else {
                j += 1
            }
        }
        return min(j, s.count)
    }

    private static func skipQuoted(_ s: [Character], from start: Int) -> Int {
        var j = start + 1
        while j < s.count {
            if s[j] == "\"" {
                if j + 1 < s.count, s[j + 1] == "\"" {
                    j += 2
                    continue
                }
                return j + 1
            }
            j += 1
        }
        return j
    }

    private static func skipLine(_ s: [Character], from start: Int) -> Int {
        var j = start
        while j < s.count {
            if s[j] == "\n" { return j + 1 }
            j += 1
        }
        return j
    }

    private static func find(_ s: [Character], _ a: Character, _ b: Character, from start: Int) -> Int? {
        var j = start
        while j + 1 < s.count {
            if s[j] == a, s[j + 1] == b { return j }
            j += 1
        }
        return nil
    }
}
