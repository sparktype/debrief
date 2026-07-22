// 메뉴바 항목 제목 (이모지 prefix, 경어체)
import Foundation

/// Pure Korean menu titles with leading Unicode emoji for the LSUIElement menu.
public enum MenuBarMenuTitles {
    public static func mcpRoot(hasProblems: Bool) -> String {
        hasProblems ? "🔌 MCP (문제 있음)" : "🔌 MCP"
    }

    public static let repairMcp = "🔧 문제 호스트 복구"

    public static func doctorRoot(hasProblems: Bool) -> String {
        hasProblems ? "🩺 진단 (문제 있음)" : "🩺 진단"
    }

    public static let doctorOK = "✅ 문제 없음"
    public static let copyDoctor = "📋 진단 요약 복사"

    public static func mute(isMuted: Bool) -> String {
        isMuted ? "🔊 음소거 해제" : "🔇 음소거"
    }

    public static func companion(enabled: Bool) -> String {
        enabled ? "🗣️ 도우미 음성 끄기" : "🗣️ 도우미 음성 켜기"
    }

    public static let modeRoot = "🎚️ 모드"
    public static let serviceStart = "▶️ 서비스 시작"
    public static let serviceStop = "⏹ 서비스 중지"
    public static let quit = "⏻ Chorus 종료"

    public static func error(_ message: String) -> String {
        "❌ 오류: \(message)"
    }
}
