// ChorusCommand 파싱 단위 테스트
import Testing
@testable import ChorusCore

@Suite("CommandsParseTests")
struct CommandsParseTests {
    @Test func emptyArgumentsLaunchMenubar() throws {
        #expect(try ChorusCommand.parse([]) == .menubar)
    }

    @Test func helpStillAvailable() throws {
        #expect(try ChorusCommand.parse(["help"]) == .help)
        #expect(try ChorusCommand.parse(["-h"]) == .help)
    }

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
