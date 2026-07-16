import Foundation
import Testing
@testable import ChorusCore

@Suite("SupertonicSmokeTests")
struct SupertonicSmokeTests {
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["CHORUS_TEST_MODEL_DIR"] != nil,
            "Set CHORUS_TEST_MODEL_DIR to run the real model smoke test."
        )
    )
    func synthesizesKoreanWithInstalledVoice() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["CHORUS_TEST_MODEL_DIR"])
        let engine = try SupertonicEngine(modelDirectory: URL(fileURLWithPath: path, isDirectory: true))

        let buffer = try await engine.synthesize(text: "테스트를 완료했습니다.", voice: "F1", speed: 0.93)

        #expect(buffer.sampleRate == 44_100)
        #expect(buffer.channels == 1)
        #expect(!buffer.samples.isEmpty)
        #expect(buffer.samples.allSatisfy { $0.isFinite })
    }
}
