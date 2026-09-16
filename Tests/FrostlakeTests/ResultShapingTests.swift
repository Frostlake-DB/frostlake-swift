import Foundation
import Testing
@testable import Frostlake

@Suite struct ResultShapingTests {

    private func column(_ name: String, _ dataType: String = "NUMBER", scale: Int = 0) -> FrostlakeColumn {
        FrostlakeColumn(name: name, dataType: dataType, nullable: false, precision: 19, scale: scale)
    }

    @Test func insertCountRowIsKeptAndCounted() {
        let rs = WireResultSet(columns: [column("number of rows inserted")], rows: [[.number("5")]])
        let shaped = ResultShaping.shapeOne(rs)
        #expect(shaped.updateCount == 5)
        #expect(shaped.rowCount == 5)
        #expect(shaped.columns.map(\.name) == ["number of rows inserted"])
        #expect(shaped.rows.count == 1)
        #expect(shaped.rows[0][0] == .int(5))
    }

    @Test func updateExcludesMultiJoinedFromCount() {
        let rs = WireResultSet(
            columns: [column("number of rows updated"), column("number of multi-joined rows updated")],
            rows: [[.number("3"), .number("2")]])
        #expect(ResultShaping.shapeOne(rs).updateCount == 3)
        #expect(ResultShaping.shapeOne(rs).rowCount == 3)
    }

    @Test func mergeSumsInsertedAndUpdated() {
        let rs = WireResultSet(
            columns: [column("number of rows inserted"), column("number of rows updated")],
            rows: [[.number("2"), .number("3")]])
        #expect(ResultShaping.shapeOne(rs).updateCount == 5)
    }

    @Test func countNamesMatchCaseInsensitively() {
        let rs = WireResultSet(columns: [column("Number Of Rows Deleted")], rows: [[.number("4")]])
        #expect(ResultShaping.shapeOne(rs).updateCount == 4)
    }

    @Test func aliasLookAlikeStaysAQueryResult() {
        let rs = WireResultSet(
            columns: [column("number of rows inserted"), column("x")],
            rows: [[.number("5"), .number("1")]])
        let shaped = ResultShaping.shapeOne(rs)
        #expect(shaped.updateCount == nil)
        #expect(shaped.rowCount == 1)
        #expect(shaped.rows.count == 1)
    }

    @Test func onlyMultiJoinedIsNotACount() {
        let rs = WireResultSet(
            columns: [column("number of multi-joined rows updated")], rows: [[.number("2")]])
        let shaped = ResultShaping.shapeOne(rs)
        #expect(shaped.updateCount == nil)
        #expect(shaped.rowCount == 1)
    }

    @Test func twoRowsAreNotACount() {
        let rs = WireResultSet(
            columns: [column("number of rows inserted")],
            rows: [[.number("1")], [.number("2")]])
        #expect(ResultShaping.shapeOne(rs).updateCount == nil)
        #expect(ResultShaping.shapeOne(rs).rowCount == 2)
    }

    @Test func theServersOwnCountDecides() {
        // A query whose column is exactly a count name -- a `->>` chain reading an INSERT's status
        // row, say -- has the shape of DML; only the server's verdict tells them apart.
        let query = WireResultSet(
            columns: [column("number of rows inserted")], rows: [[.number("9")]], updateCount: -1)
        let shapedQuery = ResultShaping.shapeOne(query)
        #expect(shapedQuery.updateCount == nil)
        #expect(shapedQuery.rowCount == 1)
        #expect(shapedQuery.rows[0][0] == .int(9))
        // The server's count is taken as given, not re-derived from the row.
        let dml = WireResultSet(
            columns: [column("number of rows updated"), column("number of multi-joined rows updated")],
            rows: [[.number("3"), .number("2")]], updateCount: 7)
        #expect(ResultShaping.shapeOne(dml).updateCount == 7)
        // DML that touched nothing counts 0, which is not the same as no count.
        let none = WireResultSet(
            columns: [column("number of rows deleted")], rows: [[.number("0")]], updateCount: 0)
        #expect(ResultShaping.shapeOne(none).updateCount == 0)
        #expect(ResultShaping.shapeOne(none).rowCount == 0)
    }

    @Test func updateCountIsReadFromTheWire() throws {
        let query = #"{"columns":[{"name":"ID","dataType":"NUMBER"}],"rows":[[1]],"updateCount":-1}"#
        #expect(WireResultSet(try JSONParser.parse(Data(query.utf8))).updateCount == -1)
        let dml = #"{"columns":[{"name":"number of rows inserted","dataType":"NUMBER"}],"rows":[[2]],"updateCount":2}"#
        #expect(WireResultSet(try JSONParser.parse(Data(dml.utf8))).updateCount == 2)
        let older = #"{"columns":[{"name":"ID","dataType":"NUMBER"}],"rows":[[1]]}"#
        #expect(WireResultSet(try JSONParser.parse(Data(older.utf8))).updateCount == nil)
    }

    @Test func queryShaping() {
        let rs = WireResultSet(
            columns: [column("I"), column("S", "VARCHAR")],
            rows: [[.number("1"), .string("a")], [.number("2"), .null]])
        let shaped = ResultShaping.shapeOne(rs)
        #expect(shaped.updateCount == nil)
        #expect(shaped.rowCount == 2)
        #expect(shaped.rows[0]["I"] == .int(1))
        #expect(shaped.rows[0]["s"] == .string("a"))   // case-insensitive lookup
        #expect(shaped.rows[1][1] == .null)
        #expect(shaped.rows[0]["missing"] == nil)
    }

    @Test func shortRowsArePaddedWithNulls() {
        let rs = WireResultSet(columns: [column("A"), column("B")], rows: [[.number("1")]])
        let shaped = ResultShaping.shapeOne(rs)
        #expect(shaped.rows[0][1] == .null)
    }

    @Test func duplicateColumnNamesFirstOccurrenceWins() {
        let rs = WireResultSet(
            columns: [column("A"), column("a", "VARCHAR")],
            rows: [[.number("1"), .string("second")]])
        let shaped = ResultShaping.shapeOne(rs)
        #expect(shaped.rows[0]["A"] == .int(1))
        #expect(shaped.rows[0]["a"] == .string("second"))   // exact match beats case-fold
        #expect(shaped.rows[0]["a "] == nil)
    }

    @Test func envelopeDecodeFromCapturedWireBody() throws {
        // Captured verbatim from a live engine (temporals probe).
        let body = #"{"errorMessage":null,"executionTimeMs":131,"resultSets":[{"columns":[{"dataType":"TIMESTAMP_NTZ","name":"NTZ","nullable":false,"precision":0,"scale":0},{"dataType":"DATE","name":"D","nullable":false,"precision":0,"scale":0}],"rowCount":1,"rows":[["2026-01-02 03:04:05.123","2026-01-02"]]}],"sessionId":"7cf2987b-13fb-48a1-a334-cc223cc03724","success":true}"#
        let envelope = WireEnvelope(root: try JSONParser.parse(Data(body.utf8)))
        #expect(envelope.success)
        #expect(envelope.errorMessage == nil)
        #expect(envelope.sessionId == "7cf2987b-13fb-48a1-a334-cc223cc03724")
        #expect(envelope.executionTimeMs == 131)
        let result = ResultShaping.shape(envelope)
        #expect(result.rowCount == 1)
        #expect(result.rows[0]["NTZ"]?.timestampValue == Date(timeIntervalSince1970: 1_767_323_045.123))
        #expect(result.rows[0]["D"]?.dateValue == Date(timeIntervalSince1970: 1_767_312_000))
    }

    @Test func errorEnvelope() throws {
        let body = #"{"errorMessage":"Syntax error near FROM","success":false,"resultSets":null}"#
        let envelope = WireEnvelope(root: try JSONParser.parse(Data(body.utf8)))
        #expect(!envelope.success)
        #expect(envelope.errorMessage == "Syntax error near FROM")
        #expect(envelope.resultSets.isEmpty)
    }

    @Test func multiStatementEnvelope() throws {
        let body = #"{"success":true,"resultSets":[{"columns":[{"name":"A","dataType":"NUMBER"}],"rows":[[1]]},{"columns":[{"name":"B","dataType":"NUMBER"}],"rows":[[2]]}]}"#
        let result = ResultShaping.shape(WireEnvelope(root: try JSONParser.parse(Data(body.utf8))))
        #expect(result.resultSets.count == 2)
        #expect(result.rows[0]["A"] == .int(1))
        #expect(result.resultSets[1].rows[0]["B"] == .int(2))
    }

    @Test func multiStatementCountIsAbsentUnlessAskedFor() {
        let plain = String(decoding: JSONText.requestBody(sql: "SELECT 1", sessionId: nil, autoCommit: true),
                           as: UTF8.self)
        #expect(!plain.contains("multiStatementCount"))
        let explicitNil = String(decoding: JSONText.requestBody(
            sql: "SELECT 1; SELECT 2", sessionId: nil, autoCommit: true, multiStatementCount: nil),
                                 as: UTF8.self)
        #expect(!explicitNil.contains("multiStatementCount"))
        let declared = String(decoding: JSONText.requestBody(
            sql: "SELECT 1; SELECT 2", sessionId: "abc", autoCommit: true, multiStatementCount: 2),
                              as: UTF8.self)
        #expect(declared == #"{"sql":"SELECT 1; SELECT 2","autoCommit":true,"sessionId":"abc","multiStatementCount":2}"#)
        // 0 is a count like any other — any number — not an absent one.
        let anyNumber = String(decoding: JSONText.requestBody(
            sql: "SELECT 1; SELECT 2", sessionId: nil, autoCommit: true, multiStatementCount: 0),
                               as: UTF8.self)
        #expect(anyNumber == #"{"sql":"SELECT 1; SELECT 2","autoCommit":true,"multiStatementCount":0}"#)
    }

    @Test func requestBodyEncoding() {
        let plain = String(decoding: JSONText.requestBody(sql: "SELECT 1", sessionId: nil, autoCommit: true),
                           as: UTF8.self)
        #expect(plain == #"{"sql":"SELECT 1","autoCommit":true}"#)
        let sql = "SELECT '" + "\u{01}" + "\"\\\n'"
        let full = String(decoding: JSONText.requestBody(sql: sql, sessionId: "abc", autoCommit: false),
                          as: UTF8.self)
        let expected = #"{"sql":"SELECT '\u0001\"\\\n'","autoCommit":false,"sessionId":"abc"}"#
        #expect(full == expected)
    }

    @Test func columnLengthIsParsedAndAbsenceStaysAbsent() throws {
        // Text and binary columns declare a width -- characters and bytes
        // respectively, the type's maximum when unbounded. Nothing else
        // carries one, and neither does a server that predates the field.
        let json =
            #"{"columns":[{"name":"S","dataType":"VARCHAR","precision":0,"scale":0,"length":9},"# +
            #"{"name":"B","dataType":"BINARY","precision":0,"scale":0,"length":5},"# +
            #"{"name":"BIG","dataType":"VARCHAR","precision":0,"scale":0,"length":16777216},"# +
            #"{"name":"N","dataType":"NUMBER","precision":10,"scale":2}],"rows":[]}"#
        let set = WireResultSet(try JSONParser.parse(Data(json.utf8)))
        #expect(set.columns[0].length == 9)
        #expect(set.columns[1].length == 5)
        #expect(set.columns[2].length == 16777216)
        #expect(set.columns[3].length == nil)
    }
}
