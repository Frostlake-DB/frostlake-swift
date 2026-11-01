import Foundation
import Testing
@testable import Frostlake

@Suite struct SubstitutionTests {

    private func sub(_ sql: String, _ binds: [FrostlakeBind]) throws -> String {
        try Substitution.substitute(sql, binds: binds)
    }

    @Test func basic() throws {
        #expect(try sub("SELECT ?", [42]) == "SELECT 42")
        #expect(try sub("SELECT ?, ?, ?", [1, "a", true]) == "SELECT 1, 'a', true")
    }

    @Test func questionInsideSingleQuotedString() throws {
        #expect(try sub("SELECT '?', ?", [1]) == "SELECT '?', 1")
        #expect(try sub("SELECT 'a''?', ?", [1]) == "SELECT 'a''?', 1")
    }

    @Test func backslashEscapeInsideString() throws {
        #expect(try sub(#"SELECT 'a\'?', ?"#, [1]) == #"SELECT 'a\'?', 1"#)
    }

    @Test func questionInsideDoubleQuotedIdentifier() throws {
        #expect(try sub(#"SELECT "a?b" FROM t WHERE x = ?"#, [7]) == #"SELECT "a?b" FROM t WHERE x = 7"#)
        #expect(try sub(#"SELECT "a""?" FROM t"#, []) == #"SELECT "a""?" FROM t"#)
    }

    @Test func questionInsideComments() throws {
        #expect(try sub("SELECT ? -- is it?\n", [1]) == "SELECT 1 -- is it?\n")
        #expect(try sub("SELECT ? // is it?\n", [1]) == "SELECT 1 // is it?\n")
        #expect(try sub("SELECT /* ? */ ?", [1]) == "SELECT /* ? */ 1")
        #expect(try sub("SELECT 1 /* unterminated ?", []) == "SELECT 1 /* unterminated ?")
        #expect(try sub("SELECT ? -- trailing?", [1]) == "SELECT 1 -- trailing?")
    }

    @Test func questionInsideDollarQuotedString() throws {
        #expect(try sub("SELECT $$a?b$$, ?", [1]) == "SELECT $$a?b$$, 1")
        #expect(try sub("SELECT $$unterminated ?", []) == "SELECT $$unterminated ?")
        // Non-greedy: $$a$$ closes at the first $$, the ? after it is a placeholder.
        #expect(try sub("$$a$$?$$b?$$", [9]) == "$$a$$9$$b?$$")
    }

    @Test func negativeNumberStaysOneValue() throws {
        // Bare, 3-? would become 3--5, a line comment, and ?::VARCHAR would cast before it negates.
        #expect(try sub("SELECT 3-?", [-5]) == "SELECT 3-(-5)")
        #expect(try sub("SELECT ?::VARCHAR", [-5]) == "SELECT (-5)::VARCHAR")
        #expect(try sub("SELECT 3-?", [.int(.min)]) == "SELECT 3-(-9223372036854775808)")
        #expect(try sub("SELECT 3-?", [-2.5]) == "SELECT 3-(-2.5)")
        #expect(try sub("SELECT 3-?", [.decimal(Decimal(string: "-2.5")!)]) == "SELECT 3-(-2.5)")
        #expect(try sub("SELECT 3-?", [.decimal(Decimal(string: "-123456789012345678901234567890")!)])
                == "SELECT 3-(-123456789012345678901234567890)")
        // The rendered text decides: -0.0 is not below zero, yet it renders with a minus.
        #expect(try sub("SELECT 3-?", [.double(-0.0)]) == "SELECT 3-(-0.0)")
        #expect(try sub("SELECT 3-?, ?", [5, 0.5]) == "SELECT 3-5, 0.5")
    }

    @Test func dollarsInsideANameOpenNoBody() throws {
        #expect(try sub("SELECT 1 AS a$$b, ?", [7]) == "SELECT 1 AS a$$b, 7")
        #expect(try sub("SELECT $$a?b$$ AS x$$, ?", [7]) == "SELECT $$a?b$$ AS x$$, 7")
    }

    @Test func lineCommentEndsAtACarriageReturn() throws {
        #expect(try sub("SELECT 1 -- c\r, ?", [7]) == "SELECT 1 -- c\r, 7")
        #expect(try sub("SELECT 1 // c\r, ?", [7]) == "SELECT 1 // c\r, 7")
        // Swift reads CR LF as one Character; it ends the comment as well.
        #expect(try sub("SELECT 1 -- c\r\n, ?", [7]) == "SELECT 1 -- c\r\n, 7")
    }

    @Test func notEnoughBinds() {
        #expect(throws: FrostlakeError.binds("not enough bind values for placeholders")) {
            _ = try Substitution.substitute("SELECT ?, ?", binds: [1])
        }
    }

    @Test func tooManyBinds() {
        #expect(throws: FrostlakeError.binds("too many bind values: 2 given, 1 placeholder")) {
            _ = try Substitution.substitute("SELECT ?", binds: [1, 2])
        }
        #expect(throws: FrostlakeError.binds("too many bind values: 2 given, 0 placeholders")) {
            _ = try Substitution.substitute("SELECT 1", binds: [1, 2])
        }
    }
}
