public enum ModePolicy {
    public static func admit(
        event: HookEventName,
        requestedVolume: Double,
        configuration: ChorusConfiguration
    ) -> Double? {
        guard !configuration.muted, requestedVolume.isFinite else { return nil }
        guard event == .stop || event == .subagentStop else { return nil }

        if event == .subagentStop {
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
