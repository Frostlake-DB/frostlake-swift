import Foundation
import Testing
@testable import Frostlake

@Suite struct TemporalTests {

    private func epoch(_ date: Date?) -> Double? {
        date?.timeIntervalSince1970
    }

    private func close(_ actual: Double?, _ expected: Double) -> Bool {
        guard let actual else { return false }
        return abs(actual - expected) < 0.0005
    }

    @Test func parseSpaceForm() {
        #expect(close(epoch(TemporalText.parseTimestamp("2026-01-02 03:04:05.123")), 1_767_323_045.123))
        #expect(close(epoch(TemporalText.parseTimestamp("2026-01-02 03:04:05")), 1_767_323_045))
    }

    @Test func parseIsoTForm() {
        #expect(close(epoch(TemporalText.parseTimestamp("2026-01-02T03:04:05")), 1_767_323_045))
    }

    @Test func trailingOffsetIsDroppedNotApplied() {
        // TIMESTAMP_LTZ/TZ wire form: the LOCAL part is the value.
        #expect(close(epoch(TemporalText.parseTimestamp("2026-01-02 03:04:05.000 +0530")), 1_767_323_045))
        #expect(close(epoch(TemporalText.parseTimestamp("2026-01-02 03:04:05 -07:00")), 1_767_323_045))
        #expect(close(epoch(TemporalText.parseTimestamp("2026-01-02 03:04:05.500 +0000")), 1_767_323_045.5))
    }

    @Test func dateOnlyTimestampIsMidnight() {
        #expect(close(epoch(TemporalText.parseTimestamp("2026-01-02")), 1_767_312_000))
    }

    @Test func parseDateTakesFirstTenCharacters() {
        #expect(close(epoch(TemporalText.parseDate("2026-01-02")), 1_767_312_000))
        #expect(close(epoch(TemporalText.parseDate("2026-01-02 03:04:05.123")), 1_767_312_000))
        #expect(close(epoch(TemporalText.parseDate("2024-02-29")), 1_709_164_800))   // leap day
    }

    @Test func parseTimeSecondsSinceMidnight() {
        #expect(TemporalText.parseTime("03:04:05") == 11_045)
        #expect(TemporalText.parseTime("03:04:05.5") == 11_045.5)
        #expect(TemporalText.parseTime("00:00:00") == 0)
        #expect(TemporalText.parseTime("23:59:59") == 86_399)
    }

    @Test func garbageAnswersNil() {
        #expect(TemporalText.parseTimestamp("garbage") == nil)
        #expect(TemporalText.parseTimestamp("") == nil)
        #expect(TemporalText.parseDate("2026-13-01") == nil)
        #expect(TemporalText.parseDate("2026-00-10") == nil)
        #expect(TemporalText.parseTime("nope") == nil)
        #expect(TemporalText.parseTime("25:00:00") == nil)
    }

    @Test func formatting() {
        #expect(TemporalText.formatTimestamp(Date(timeIntervalSince1970: 1_767_323_045.123))
            == "2026-01-02T03:04:05.123")
        #expect(TemporalText.formatDate(Date(timeIntervalSince1970: 1_767_323_045.123)) == "2026-01-02")
        // Pre-epoch exercises negative floor division.
        #expect(TemporalText.formatTimestamp(Date(timeIntervalSince1970: -14_182_940))
            == "1969-07-20T20:17:40.000")
        #expect(TemporalText.formatDate(Date(timeIntervalSince1970: -14_182_940)) == "1969-07-20")
        #expect(TemporalText.formatDate(Date(timeIntervalSince1970: 1_709_208_000)) == "2024-02-29")
    }

    @Test func formatParseRoundTrip() {
        let original = Date(timeIntervalSince1970: 1_767_323_045.123)
        let text = TemporalText.formatTimestamp(original)
        #expect(close(epoch(TemporalText.parseTimestamp(text)), 1_767_323_045.123))
    }
}
