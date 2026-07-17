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
    }

    @Test func lastErrorIsOptionalAndEquatable() {
        let a = MenuBarStatus(serviceRunning: true, muted: false, mode: .quiet, lastError: nil)
        let b = MenuBarStatus(serviceRunning: true, muted: false, mode: .quiet)
        let c = MenuBarStatus(serviceRunning: true, muted: false, mode: .quiet, lastError: "boom")
        #expect(a == b)
        #expect(a != c)
        #expect(c.lastError == "boom")
    }

    @Test func statusItemTitleShowsActiveVoiceOnlyWhileSpeaking() {
        let idle = MenuBarStatus(serviceRunning: true, muted: false, mode: .normal)
        #expect(idle.statusItemTitle == "")
        #expect(!idle.summaryLine.contains("F1"))

        let speaking = MenuBarStatus(
            serviceRunning: true,
            muted: false,
            mode: .normal,
            activeVoice: "M3"
        )
        #expect(speaking.statusItemTitle == "M3")
        #expect(speaking.summaryLine.contains("M3"))
    }
}
