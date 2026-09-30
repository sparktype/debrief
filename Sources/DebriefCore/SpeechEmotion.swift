/// Restrained affective stance for companion speech (closed enum).
public enum SpeechEmotion: String, Codable, Equatable, Sendable, CaseIterable {
    case neutral
    case warm
    case focused
    case concerned
    case relieved
    case tired
}

/// Maps emotion to mechanical speed/volume bias; does not rewrite text.
public enum EmotionProsody {
    /// Multiplies agent-provided speed/volume, then clamps to legal speak ranges.
    public static func apply(
        emotion: SpeechEmotion,
        speed: Double,
        volume: Double
    ) -> (speed: Double, volume: Double) {
        let factors: (speed: Double, volume: Double)
        switch emotion {
        case .neutral:
            factors = (1.0, 1.0)
        case .warm:
            factors = (0.97, 1.0)
        case .focused:
            factors = (1.02, 1.0)
        case .concerned:
            factors = (0.95, 1.05)
        case .relieved:
            factors = (0.98, 1.0)
        case .tired:
            factors = (0.92, 0.90)
        }
        let biasedSpeed = min(2.0, max(0.7, speed * factors.speed))
        let biasedVolume = min(1.0, max(0.0, volume * factors.volume))
        return (biasedSpeed, biasedVolume)
    }
}
