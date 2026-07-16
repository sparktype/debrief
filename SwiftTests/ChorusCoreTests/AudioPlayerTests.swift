import Testing
@testable import ChorusCore

@Suite("AudioPlayerTests")
struct AudioPlayerTests {
    @Test func scalesGainAndRebuildsExactlyOnceAfterDriverFailure() async throws {
        let driver = FakeAudioDriver(failFirstPlay: true)
        let player = AudioPlayer(driver: driver)
        let buffer = PCMBuffer(sampleRate: 44_100, channels: 1, samples: [1, -0.5, 2])

        try await player.play(buffer, gain: 0.4)

        #expect(await driver.rebuildCount == 1)
        #expect(await driver.playAttempts == 2)
        #expect(await driver.lastSamples == [0.4, -0.2, 0.8])
    }

    @Test func rejectsInvalidPCMWithoutCallingDriver() async {
        let driver = FakeAudioDriver(failFirstPlay: false)
        let player = AudioPlayer(driver: driver)

        await #expect(throws: AudioPlayerError.invalidBuffer) {
            try await player.play(
                PCMBuffer(sampleRate: 44_100, channels: 2, samples: [0, 0]),
                gain: 1
            )
        }
        #expect(await driver.playAttempts == 0)
    }
}

private actor FakeAudioDriver: AudioEngineDriving {
    private let failFirstPlay: Bool
    private(set) var playAttempts = 0
    private(set) var rebuildCount = 0
    private(set) var lastSamples: [Float] = []

    init(failFirstPlay: Bool) {
        self.failFirstPlay = failFirstPlay
    }

    func play(samples: [Float], sampleRate: Double) async throws {
        playAttempts += 1
        if failFirstPlay, playAttempts == 1 { throw AudioPlayerError.playbackFailed }
        lastSamples = samples
    }

    func stop() async {}

    func rebuild() async throws {
        rebuildCount += 1
    }
}
