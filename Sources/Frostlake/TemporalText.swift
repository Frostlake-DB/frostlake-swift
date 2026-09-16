import Foundation

/// Parsing and formatting for the wire's temporal text, matching the engine's
/// JDBC marshaling: TIMESTAMP_NTZ crosses as "2026-01-02 03:04:05.123" (a 'T'
/// separator is accepted too), TIMESTAMP_LTZ/TZ with a trailing numeric offset
/// ("… +0530") whose LOCAL part is the value getString reports, DATE as
/// "2026-01-02", TIME as "03:04:05". Parsed Dates place that wall-clock
/// reading at UTC. Calendar math is done directly (days-from-civil), so no
/// Calendar/TimeZone state is involved.
enum TemporalText {

    static func parseTimestamp(_ text: String) -> Date? {
        var s = Substring(text.trimmingCharacters(in: .whitespaces))
        // Drop a trailing ±HHMM / ±HH:MM zone offset (the TIMESTAMP_LTZ/TZ wire form).
        if let sp = s.lastIndex(of: " "), isNumericOffset(s[s.index(after: sp)...]) {
            s = s[..<sp]
        }
        var sep: Substring.Index?
        for index in s.indices where s[index] == "T" || s[index] == " " {
            sep = index
            break
        }
        let datePart = sep == nil ? s : s[..<sep!]
        guard let days = civilDays(datePart) else { return nil }
        var seconds = 0.0
        if let sep {
            guard let t = daySeconds(s[s.index(after: sep)...]) else { return nil }
            seconds = t
        }
        return Date(timeIntervalSince1970: Double(days) * 86_400 + seconds)
    }

    /// The first 10 characters as a calendar date — mirroring the JDBC
    /// driver's getDate, a timestamp string's date part qualifies.
    static func parseDate(_ text: String) -> Date? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard let days = civilDays(Substring(s.prefix(10))) else { return nil }
        return Date(timeIntervalSince1970: Double(days) * 86_400)
    }

    /// "HH:MM:SS[.fff]" as seconds since midnight.
    static func parseTime(_ text: String) -> TimeInterval? {
        daySeconds(Substring(text.trimmingCharacters(in: .whitespaces)))
    }

    /// UTC wall clock with milliseconds, no zone suffix — the JS/JDBC bind
    /// form: "2026-01-02T03:04:05.123".
    static func formatTimestamp(_ date: Date) -> String {
        let totalMs = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let (days, msOfDay) = floorDivide(totalMs, by: 86_400_000)
        let (y, m, d) = civilFromDays(days)
        let hh = msOfDay / 3_600_000
        let mm = msOfDay % 3_600_000 / 60_000
        let ss = msOfDay % 60_000 / 1000
        let ms = msOfDay % 1000
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d",
                      Int(y), Int(m), Int(d), Int(hh), Int(mm), Int(ss), Int(ms))
    }

    static func formatDate(_ date: Date) -> String {
        let totalMs = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let (days, _) = floorDivide(totalMs, by: 86_400_000)
        let (y, m, d) = civilFromDays(days)
        return String(format: "%04d-%02d-%02d", Int(y), Int(m), Int(d))
    }

    // ── internals ──────────────────────────────────────────────────────────

    /// Whether a trailing token is a ±HHMM / ±HH:MM zone offset rather than text.
    private static func isNumericOffset(_ token: Substring) -> Bool {
        guard token.count >= 3, token.first == "+" || token.first == "-" else { return false }
        for ch in token.dropFirst() {
            if ch != ":" && !(ch >= "0" && ch <= "9") { return false }
        }
        return true
    }

    /// "yyyy-mm-dd" → days since 1970-01-01 (Howard Hinnant's civil-days algorithm).
    private static func civilDays(_ s: Substring) -> Int64? {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let year = Int64(parts[0]), let month = Int64(parts[1]), let day = Int64(parts[2]),
              month >= 1, month <= 12, day >= 1, day <= 31 else {
            return nil
        }
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civilFromDays(_ z0: Int64) -> (Int64, Int64, Int64) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    private static func daySeconds(_ s: Substring) -> Double? {
        let dot = s.firstIndex(of: ".")
        let hms = dot == nil ? s : s[..<dot!]
        let parts = hms.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let h = Int(parts[0]), let m = Int(parts[1]) else {
            return nil
        }
        var seconds = 0
        if parts.count == 3 {
            guard let ss = Int(parts[2]) else { return nil }
            seconds = ss
        }
        guard h >= 0, h < 24, m >= 0, m < 60, seconds >= 0, seconds < 62 else { return nil }
        var fraction = 0.0
        if let dot {
            let digits = s[s.index(after: dot)...]
            guard !digits.isEmpty, let f = Double("0." + digits) else { return nil }
            fraction = f
        }
        return Double(h * 3600 + m * 60 + seconds) + fraction
    }

    private static func floorDivide(_ a: Int64, by b: Int64) -> (Int64, Int64) {
        var quotient = a / b
        var remainder = a % b
        if remainder < 0 {
            quotient -= 1
            remainder += b
        }
        return (quotient, remainder)
    }
}
