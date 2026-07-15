import Foundation
import Testing
@testable import ChorusCore

@Suite("SpeechEnvelopeParserTests")
struct SpeechEnvelopeParserTests {
    @Test func extractsLastValidEnvelope() {
        let message = """
        visible
        <!-- chorus:speak {"v":1,"text":"first","voice":"F1","speed":0.93,"volume":0.8} -->
        <!-- chorus:speak {"v":1,"text":"완료했습니다.","voice":"M4","speed":0.95,"volume":0.7} -->
        """

        let value = SpeechEnvelopeParser.extract(from: message)

        #expect(value?.text == "완료했습니다.")
        #expect(value?.voice == "M4")
    }

    @Test(arguments: [
        "<!-- chorus:speak {\"v\":1,\"text\":\"\",\"voice\":\"F1\",\"speed\":1,\"volume\":1} -->",
        "<!-- chorus:speak {\"v\":1,\"text\":\"x\",\"voice\":\"BAD\",\"speed\":1,\"volume\":1} -->",
        "<!-- chorus:speak {\"v\":1,\"text\":\"x\",\"voice\":\"F1\",\"speed\":2.1,\"volume\":1} -->",
        "<!-- chorus:speak {\"v\":1,\"text\":\"x\",\"voice\":\"F1\",\"speed\":1,\"volume\":1,\"extra\":true} -->",
        "<!-- chorus:speak {\"v\":1, -->",
        "<!-- chorus:speak {\"v\":1,\"text\":\"x\",\"voice\":\"F1\",\"speed\":1} -->",
    ])
    func rejectsInvalidEnvelope(_ raw: String) {
        #expect(SpeechEnvelopeParser.extract(from: raw) == nil)
    }

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

    @Test func skipsInvalidTrailingEnvelope() {
        let message = """
        <!-- chorus:speak {"v":1,"text":"valid","voice":"F2","speed":1,"volume":0.5} -->
        <!-- chorus:speak {"v":1,"text":"invalid","voice":"BAD","speed":1,"volume":0.5} -->
        """

        #expect(SpeechEnvelopeParser.extract(from: message)?.text == "valid")
    }
}
