// Menu bar emoji title helpers
import Testing
@testable import ChorusCore

@Suite("MenuBarMenuTitlesTests")
struct MenuBarMenuTitlesTests {
    @Test func mcpRootReflectsProblems() {
        #expect(MenuBarMenuTitles.mcpRoot(hasProblems: false) == "🔌 MCP")
        #expect(MenuBarMenuTitles.mcpRoot(hasProblems: true) == "🔌 MCP (문제 있음)")
    }

    @Test func muteAndCompanionTitles() {
        #expect(MenuBarMenuTitles.mute(isMuted: false) == "🔇 음소거")
        #expect(MenuBarMenuTitles.mute(isMuted: true) == "🔊 음소거 해제")
        #expect(MenuBarMenuTitles.companion(enabled: true) == "🗣️ 도우미 음성 끄기")
        #expect(MenuBarMenuTitles.companion(enabled: false) == "🗣️ 도우미 음성 켜기")
    }

    @Test func serviceAndDoctorTitles() {
        #expect(MenuBarMenuTitles.serviceStart == "▶️ 서비스 시작")
        #expect(MenuBarMenuTitles.serviceStop == "⏹ 서비스 중지")
        #expect(MenuBarMenuTitles.doctorRoot(hasProblems: false) == "🩺 진단")
        #expect(MenuBarMenuTitles.doctorRoot(hasProblems: true) == "🩺 진단 (문제 있음)")
        #expect(MenuBarMenuTitles.doctorOK == "✅ 문제 없음")
        #expect(MenuBarMenuTitles.copyDoctor == "📋 진단 요약 복사")
        #expect(MenuBarMenuTitles.repairMcp == "🔧 문제 호스트 복구")
        #expect(MenuBarMenuTitles.quit == "⏻ Chorus 종료")
        #expect(MenuBarMenuTitles.modeRoot == "🎚️ 모드")
    }

    @Test func errorPrefix() {
        #expect(MenuBarMenuTitles.error("boom") == "❌ 오류: boom")
    }
}
