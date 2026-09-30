import Foundation
import Testing
@testable import DebriefCore

@Suite("SupertonicTensorTests")
struct SupertonicTensorTests {
    @Test func padsRowsAndBuildsMasksDeterministically() {
        let padded = SupertonicTensor.pad([[Int64(4), 5], [Int64(9)]], with: 0)

        #expect(padded.values == [4, 5, 9, 0])
        #expect(padded.rows == 2)
        #expect(padded.columns == 2)
        #expect(SupertonicTensor.lengthMask([2, 1], maxLength: 3) == [1, 1, 0, 1, 0, 0])
    }

    @Test func concatenatesChunksWithExactSilence() {
        #expect(
            SupertonicTensor.concatenate([[0.25, 0.5], [-0.5]], silenceSamples: 2)
                == [0.25, 0.5, 0, 0, -0.5]
        )
    }

    @Test func convertsNativeFloatTensorData() {
        let source: [Float] = [-1, -0.25, 0, 0.5, 1]
        let data = source.withUnsafeBytes { Data($0) }

        #expect(SupertonicTensor.floatSamples(from: data) == source)
    }

    @Test func splitsKoreanSentencesWithoutDroppingPunctuation() {
        #expect(
            SupertonicTensor.splitText("첫 문장입니다. 두 번째인가요? 네!", maxLength: 10)
                == ["첫 문장입니다.", "두 번째인가요?", "네!"]
        )
        #expect(
            SupertonicTensor.splitText("Dr. Kim arrived. Ready?", maxLength: 18)
                == ["Dr. Kim arrived.", "Ready?"]
        )
    }

    @Test func pcmBufferCarriesMonoFloatSamples() {
        let buffer = PCMBuffer(sampleRate: 44_100, channels: 1, samples: [0, 0.5, -0.5])

        #expect(buffer.sampleRate == 44_100)
        #expect(buffer.channels == 1)
        #expect(buffer.samples == [0, 0.5, -0.5])
    }
}
