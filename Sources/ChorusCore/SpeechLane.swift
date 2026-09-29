/// Speech content lane: turn briefing vs factual work report.
public enum SpeechLane: String, Codable, Equatable, Sendable, CaseIterable {
    /// What changed, then one next action; prefer F1; may be disabled by user.
    case companion
    /// Factual work report; role voice; subject to subagent priority rules.
    case work
}
