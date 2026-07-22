// MenuBarStatus.summaryLine 단위 테스트
import Foundation
import Testing
@testable import ChorusCore

@Suite("MenuBarStatusTests")
struct MenuBarStatusTests {
    @Test func statusLineSummarizesRunningMutedMode() {
        let line = MenuBarStatus(
            serviceRunning: true,
            muted: true,
            mode: .focus
        ).summaryLine
        #expect(line.contains("실행 중"))
        #expect(line.contains("음소거"))
        #expect(line.contains("focus"))
        #expect(line.contains("도우미"))
    }

    @Test func statusLineSummarizesStoppedUnmutedMode() {
        let line = MenuBarStatus(
            serviceRunning: false,
            muted: false,
            mode: .normal
        ).summaryLine
        #expect(line.contains("중지됨"))
        #expect(line.contains("음성 사용"))
        #expect(line.contains("normal"))
        #expect(line.contains("도우미 켜짐"))
    }

    @Test func lastErrorIsOptionalAndEquatable() {
        let a = MenuBarStatus(serviceRunning: true, muted: false, mode: .quiet, lastError: nil)
        let b = MenuBarStatus(serviceRunning: true, muted: false, mode: .quiet)
        let c = MenuBarStatus(serviceRunning: true, muted: false, mode: .quiet, lastError: "boom")
        #expect(a == b)
        #expect(a != c)
        #expect(c.lastError == "boom")
    }

    @Test func isSpeakingReflectsActiveVoiceForBadgeIcon() {
        let idle = MenuBarStatus(serviceRunning: true, muted: false, mode: .normal)
        #expect(!idle.isSpeaking)
        #expect(!idle.summaryLine.contains("F1"))

        let speaking = MenuBarStatus(
            serviceRunning: true,
            muted: false,
            mode: .normal,
            activeVoice: "M3"
        )
        #expect(speaking.isSpeaking)
        #expect(speaking.activeVoice == "M3")
        #expect(speaking.summaryLine.contains("M3"))
    }

    @Test func doctorLinesSurfaceProblems() {
        let healthy = MenuBarStatus(serviceRunning: true, muted: false, mode: .normal)
        #expect(!healthy.hasDoctorProblems)
        let sick = MenuBarStatus(
            serviceRunning: false,
            muted: false,
            mode: .normal,
            doctorLines: ["[문제] daemon.missing — chorus install --repair"]
        )
        #expect(sick.hasDoctorProblems)
        #expect(sick.doctorLines.count == 1)
    }

    @Test func companionDisabledShowsInSummary() {
        let line = MenuBarStatus(
            serviceRunning: true,
            muted: false,
            companionEnabled: false,
            mode: .normal
        ).summaryLine
        #expect(line.contains("도우미 꺼짐"))
    }

    @Test func mcpLinesAndProblemsSurfaceInStatus() {
        let healthy = MenuBarStatus(
            serviceRunning: true,
            muted: false,
            mode: .normal,
            mcpLines: ["✅ Claude: 등록됨", "⚪ Codex: 설정 없음", "⚪ Grok: 설정 없음"],
            hasMcpProblems: false
        )
        #expect(!healthy.hasMcpProblems)
        #expect(healthy.mcpLines.count == 3)

        let sick = MenuBarStatus(
            serviceRunning: true,
            muted: false,
            mode: .normal,
            mcpLines: ["⚠️ Claude: 미등록"],
            hasMcpProblems: true
        )
        #expect(sick.hasMcpProblems)
        #expect(sick.mcpLines.first?.hasPrefix("⚠️") == true)
    }
}
