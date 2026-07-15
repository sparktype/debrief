import Foundation

public enum EnvelopeError: Error, Equatable, Sendable {
    case unsupportedVersion
    case invalidText
    case invalidVoice
    case invalidSpeed
    case invalidVolume
}

public struct SpeechEnvelope: Codable, Equatable, Sendable {
    public let v: Int
    public let text: String
    public let voice: String
    public let speed: Double
    public let volume: Double

    public init(v: Int, text: String, voice: String, speed: Double, volume: Double) {
        self.v = v
        self.text = text
        self.voice = voice
        self.speed = speed
        self.volume = volume
    }

    public func validate(
        allowedVoices: Set<String> = Set([
            "F1", "F2", "F3", "F4", "F5",
            "M1", "M2", "M3", "M4", "M5",
        ])
    ) throws {
        guard v == 1 else { throw EnvelopeError.unsupportedVersion }
        guard !text.isEmpty, text.count <= 800, !text.contains("-->") else {
            throw EnvelopeError.invalidText
        }
        guard text.unicodeScalars.allSatisfy({ scalar in
            !CharacterSet.controlCharacters.contains(scalar) || scalar.value == 0x0A
        }) else {
            throw EnvelopeError.invalidText
        }
        guard allowedVoices.contains(voice) else { throw EnvelopeError.invalidVoice }
        guard speed.isFinite, (0.7...2.0).contains(speed) else {
            throw EnvelopeError.invalidSpeed
        }
        guard volume.isFinite, (0.0...1.0).contains(volume) else {
            throw EnvelopeError.invalidVolume
        }
    }
}
