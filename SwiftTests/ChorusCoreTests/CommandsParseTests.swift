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

    @Test func parsesMenubarAndHook() throws {
        #expect(try ChorusCommand.parse(["menubar"]) == .menubar)
        #expect(try ChorusCommand.parse(["hook", "--source", "claude"]) == .hook(source: "claude"))
    }

    @Test func rejectsRemovedCLICommands() {
        for name in ["daemon", "speak", "status", "mute", "mode", "doctor"] {
            #expect(throws: CommandError.self) {
                try ChorusCommand.parse([name])
            }
        }
    }

    @Test func menubarRejectsExtraArguments() {
        #expect(throws: CommandError.usage("menubar accepts no arguments")) {
            try ChorusCommand.parse(["menubar", "--extra"])
        }
    }
}
