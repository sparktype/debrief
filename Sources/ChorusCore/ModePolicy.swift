/// Mute, mode, companion toggle, and volume-ceiling policy for admitted speech.
public enum ModePolicy {
    /// Returns effective playback gain, or `nil` when the request must be dropped.
    ///
    /// - `muted`: all speech rejected
    /// - `companionEnabled == false`: reject `.companion` lane
    /// - `focus` / `quiet` / `night`: reject `.subagent` priority only
    /// - volume ceilings: clamp gain per mode (`quiet` 0.45, `night` 0.20 by default)
    public static func admit(
        priority: SpeechPriority,
        lane: SpeechLane = .companion,
        requestedVolume: Double,
        configuration: ChorusConfiguration
    ) -> Double? {
        guard !configuration.muted, requestedVolume.isFinite else { return nil }

        if lane == .companion, !configuration.companionEnabled {
            return nil
        }

        if priority == .subagent {
            switch configuration.mode {
            case .focus, .quiet, .night:
                return nil
            case .normal, .verbose:
                break
            }
        }

        let ceiling = configuration.volumeCeilings[configuration.mode.rawValue]
            ?? ChorusConfiguration.defaultVolumeCeilings[configuration.mode.rawValue]
            ?? 1.0
        return min(max(requestedVolume, 0.0), min(max(ceiling, 0.0), 1.0))
    }
}
