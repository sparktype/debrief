// 메뉴바 상태 스냅샷 및 한 줄 요약 문자열
import Foundation

/// Pure status snapshot for the LSUIElement menu bar (testable without AppKit).
public struct MenuBarStatus: Equatable, Sendable {
    public var serviceRunning: Bool
    public var muted: Bool
    public var companionEnabled: Bool
    public var mode: ChorusMode
    /// Currently speaking voice ID (`F1`…`M5`), or `nil` when idle.
    public var activeVoice: String?
    public var lastError: String?
    /// Failed doctor findings for the diagnostics submenu (empty when healthy).
    public var doctorLines: [String]
    /// Per-host MCP menu lines (emoji + label), always one per `HostSource`.
    public var mcpLines: [String]
    /// True when any host MCP wiring is a repairable problem.
    public var hasMcpProblems: Bool

    public init(
        serviceRunning: Bool,
        muted: Bool,
        companionEnabled: Bool = true,
        mode: ChorusMode,
        activeVoice: String? = nil,
        lastError: String? = nil,
        doctorLines: [String] = [],
        mcpLines: [String] = [],
        hasMcpProblems: Bool = false
    ) {
        self.serviceRunning = serviceRunning
        self.muted = muted
        self.companionEnabled = companionEnabled
        self.mode = mode
        self.activeVoice = activeVoice
        self.lastError = lastError
        self.doctorLines = doctorLines
        self.mcpLines = mcpLines
        self.hasMcpProblems = hasMcpProblems
    }

    /// 메뉴 헤더용 한 줄 요약 (한국어).
    public var summaryLine: String {
        let service = serviceRunning ? "서비스 실행 중" : "서비스 중지됨"
        let mute = muted ? "음소거" : "음성 사용"
        let companion = companionEnabled ? "도우미 켜짐" : "도우미 꺼짐"
        if let activeVoice, !activeVoice.isEmpty {
            return "\(service) · \(mute) · \(companion) · \(mode.rawValue) · \(activeVoice)"
        }
        return "\(service) · \(mute) · \(companion) · \(mode.rawValue)"
    }

    public var isSpeaking: Bool {
        if let activeVoice, !activeVoice.isEmpty { return true }
        return false
    }

    public var hasDoctorProblems: Bool {
        !doctorLines.isEmpty
    }
}
