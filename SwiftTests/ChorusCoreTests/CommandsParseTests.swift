// ChorusCommand 파싱 단위 테스트
import Testing
@testable import ChorusCore

@Suite("CommandsParseTests")
struct CommandsParseTests {
    @Test func parsesMenubar() throws {
        #expect(try ChorusCommand.parse(["menubar"]) == .menubar)
    }

    @Test func parsesDaemon() throws {
        #expect(try ChorusCommand.parse(["daemon"]) == .daemon)
    }

    @Test func menubarRejectsExtraArguments() {
        #expect(throws: CommandError.usage("menubar accepts no arguments")) {
            try ChorusCommand.parse(["menubar", "--extra"])
        }
    }
}
