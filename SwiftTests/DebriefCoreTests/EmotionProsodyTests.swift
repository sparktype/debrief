import Testing
@testable import DebriefCore

@Suite("EmotionProsodyTests")
struct EmotionProsodyTests {
    @Test func neutralLeavesValues() {
        let r = EmotionProsody.apply(emotion: .neutral, speed: 1.0, volume: 0.8)
        #expect(r.speed == 1.0)
        #expect(r.volume == 0.8)
    }

    @Test func tiredSlowsAndSoftens() {
        let r = EmotionProsody.apply(emotion: .tired, speed: 1.0, volume: 1.0)
        #expect(r.speed == 0.92)
        #expect(r.volume == 0.90)
    }

    @Test func clampsToLegalRanges() {
        let high = EmotionProsody.apply(emotion: .focused, speed: 2.0, volume: 1.0)
        #expect(high.speed == 2.0)
        let low = EmotionProsody.apply(emotion: .tired, speed: 0.7, volume: 0.0)
        #expect(low.speed == 0.7)
        #expect(low.volume == 0.0)
    }
}
