// DebriefCommand 파싱 단위 테스트
import Testing
@testable import DebriefCore

@Suite("CommandsParseTests")
struct CommandsParseTests {
    @Test func emptyArgumentsPrintHelp() throws {
        #expect(try DebriefCommand.parse([]) == .help)
    }

    @Test func helpStillAvailable() throws {
        #expect(try DebriefCommand.parse(["help"]) == .help)
        #expect(try DebriefCommand.parse(["-h"]) == .help)
    }

    @Test func parsesDaemonControls() throws {
        #expect(try DebriefCommand.parse(["daemon"]) == .daemon)
        #expect(try DebriefCommand.parse(["start"]) == .start)
        #expect(try DebriefCommand.parse(["stop"]) == .stop)
        #expect(try DebriefCommand.parse(["status"]) == .status)
        #expect(try DebriefCommand.parse(["doctor"]) == .doctor)
        #expect(try DebriefCommand.parse(["mute"]) == .mute(nil))
        #expect(try DebriefCommand.parse(["mute", "on"]) == .mute("on"))
        #expect(try DebriefCommand.parse(["mute", "off"]) == .mute("off"))
        #expect(try DebriefCommand.parse(["mute", "toggle"]) == .mute("toggle"))
        #expect(try DebriefCommand.parse(["mode"]) == .mode(nil))
        #expect(try DebriefCommand.parse(["mode", "night"]) == .mode("night"))
        #expect(try DebriefCommand.parse(["companion"]) == .companion(nil))
        #expect(try DebriefCommand.parse(["companion", "off"]) == .companion("off"))
        #expect(try DebriefCommand.parse(["hook", "--source", "claude"]) == .hook(source: "claude"))
    }

    @Test func rejectsMenubarAndSpeak() {
        for name in ["menubar", "speak"] {
            #expect(throws: CommandError.self) {
                try DebriefCommand.parse([name])
            }
        }
    }

    @Test func rejectsInvalidControlArguments() {
        #expect(throws: CommandError.self) {
            try DebriefCommand.parse(["daemon", "--extra"])
        }
        #expect(throws: CommandError.self) {
            try DebriefCommand.parse(["mute", "maybe"])
        }
        #expect(throws: CommandError.self) {
            try DebriefCommand.parse(["mode", "loud"])
        }
        #expect(throws: CommandError.self) {
            try DebriefCommand.parse(["companion", "maybe"])
        }
    }

    @Test func controlMessagesMatchTheCliContract() {
        #expect(CliMessages.muted == "음소거했습니다.")
        #expect(CliMessages.unmuted == "음소거를 해제했습니다.")
        #expect(CliMessages.companionOn == "도우미 음성을 켰습니다.")
        #expect(CliMessages.companionOff == "도우미 음성을 껐습니다.")
        #expect(CliMessages.currentMode("night") == "현재 모드는 night입니다.")
        #expect(CliMessages.modeSet("focus") == "모드를 focus로 설정했습니다.")
        #expect(CliMessages.started == "서비스를 시작했습니다.")
        #expect(CliMessages.stopped == "서비스를 중지했습니다.")
        #expect(CliMessages.alreadyRunning == "이미 실행 중입니다.")
        #expect(CliMessages.launchAgentMissing == "LaunchAgent가 없습니다. debrief install을 실행하세요.")
        #expect(CliMessages.startFailed("boom") == "서비스를 시작하지 못했습니다. boom")
        #expect(CliMessages.stopFailed("boom") == "서비스를 중지하지 못했습니다. boom")
        #expect(CliMessages.configSaveFailed("boom") == "설정을 저장하지 못했습니다. boom")
        #expect(
            CliMessages.executablePathIsDirectory
                == "실행 파일 경로가 디렉터리입니다. ~/.local/bin/debrief 를 비운 뒤 다시 설치하세요."
        )
        #expect(!DebriefCommand.usageText.localizedCaseInsensitiveContains("menu bar"))
        #expect(!DebriefCommand.usageText.contains("menubar"))
    }

    @Test func parsesMcp() throws {
        #expect(try DebriefCommand.parse(["mcp"]) == .mcp)
    }

    @Test func mcpRejectsExtraArguments() {
        #expect(throws: CommandError.self) {
            try DebriefCommand.parse(["mcp", "--extra"])
        }
    }

    @Test func parsesInstallGrokFlag() throws {
        #expect(
            try DebriefCommand.parse(["install", "--grok"])
                == .install(codex: false, claude: false, grok: true, repair: false)
        )
        #expect(
            try DebriefCommand.parse(["install", "--codex", "--claude", "--grok", "--repair"])
                == .install(codex: true, claude: true, grok: true, repair: true)
        )
    }

    @Test func parsesUninstallGrokFlag() throws {
        #expect(
            try DebriefCommand.parse(["uninstall", "--grok"])
                == .uninstall(codex: false, claude: false, grok: true)
        )
    }
}
