public struct PCMBuffer: Equatable, Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let samples: [Float]

    public init(sampleRate: Double, channels: Int, samples: [Float]) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.samples = samples
    }
}

public protocol TTSBackend: Sendable {
    func synthesize(text: String, voice: String, speed: Double) async throws -> PCMBuffer
}
