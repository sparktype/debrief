// SpeechEnvelope.validate 단위 검증
import Foundation
import Testing
@testable import DebriefCore

@Suite("SpeechEnvelopeValidationTests")
struct SpeechEnvelopeValidationTests {
    @Test func rejectsUnsafeTextAndNumbers() throws {
        var envelope = SpeechEnvelope(v: 1, text: String(repeating: "가", count: 801), voice: "F1", speed: 1, volume: 1)
        #expect(throws: EnvelopeError.invalidText) { try envelope.validate() }

        envelope = SpeechEnvelope(v: 1, text: "bad\ttext", voice: "F1", speed: 1, volume: 1)
        #expect(throws: EnvelopeError.invalidText) { try envelope.validate() }

        envelope = SpeechEnvelope(v: 1, text: "x", voice: "F1", speed: .nan, volume: 1)
        #expect(throws: EnvelopeError.invalidSpeed) { try envelope.validate() }

        envelope = SpeechEnvelope(v: 1, text: "x", voice: "F1", speed: 1, volume: .infinity)
        #expect(throws: EnvelopeError.invalidVolume) { try envelope.validate() }
    }
}
