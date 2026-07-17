// 메뉴바 상태 스냅샷 및 한 줄 요약 문자열
import Foundation

/// Pure status snapshot for the LSUIElement menu bar (testable without AppKit).
public struct MenuBarStatus: Equatable, Sendable {
    public var serviceRunning: Bool
    public var muted: Bool
    public var mode: ChorusMode
    /// Currently speaking voice ID (`F1`…`M5`), or `nil` when idle.
    public var activeVoice: String?
    public var lastError: String?

    public init(
        serviceRunning: Bool,
        muted: Bool,
        mode: ChorusMode,
        activeVoice: String? = nil,
        lastError: String? = nil
    ) {
        self.serviceRunning = serviceRunning
        self.muted = muted
        self.mode = mode
        self.activeVoice = activeVoice
        self.lastError = lastError
    }

    /// 메뉴 헤더용 한 줄 요약 (한국어).
    public var summaryLine: String {
        let service = serviceRunning ? "서비스 실행 중" : "서비스 중지됨"
        let mute = muted ? "음소거" : "음성 사용"
        if let activeVoice, !activeVoice.isEmpty {
            return "\(service) · \(mute) · \(mode.rawValue) · \(activeVoice)"
        }
        return "\(service) · \(mute) · \(mode.rawValue)"
    }

    /// Whether the status item should show a speaking-voice badge icon.
    public var isSpeaking: Bool {
        if let activeVoice, !activeVoice.isEmpty { return true }
        return false
    }
}
