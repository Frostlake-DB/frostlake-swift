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
