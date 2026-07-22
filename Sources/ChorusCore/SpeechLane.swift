/// Speech content lane: reflective companion vs factual work report.
public enum SpeechLane: String, Codable, Equatable, Sendable, CaseIterable {
    /// Observe + meaning + one next step; prefer F1; may be disabled by user.
    case companion
    /// Factual work report; role voice; subject to subagent priority rules.
    case work
}
