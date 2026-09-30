import AVFoundation
import Foundation

public enum AudioPlayerError: Error, Equatable, Sendable {
    case invalidBuffer
    case playbackFailed
}

public protocol AudioPlaying: Sendable {
    func play(_ buffer: PCMBuffer, gain: Double) async throws
    func stop() async
}

protocol AudioEngineDriving: Sendable {
    func play(samples: [Float], sampleRate: Double) async throws
    func stop() async
    func rebuild() async throws
}

public actor AudioPlayer: AudioPlaying {
    private let driver: any AudioEngineDriving

    public init() {
        driver = AVFoundationAudioDriver()
    }

    init(driver: any AudioEngineDriving) {
        self.driver = driver
    }

    public func play(_ buffer: PCMBuffer, gain: Double) async throws {
        guard buffer.channels == 1,
              buffer.sampleRate == 44_100,
              !buffer.samples.isEmpty,
              buffer.samples.count <= Int(AVAudioFrameCount.max),
              buffer.samples.allSatisfy(\.isFinite),
              gain.isFinite else {
            throw AudioPlayerError.invalidBuffer
        }
        let admittedGain = Float(min(max(gain, 0), 1))
        let samples = buffer.samples.map { $0 * admittedGain }
        do {
            try await driver.play(samples: samples, sampleRate: buffer.sampleRate)
        } catch {
            try await driver.rebuild()
            try await driver.play(samples: samples, sampleRate: buffer.sampleRate)
        }
    }

    public func stop() async {
        await driver.stop()
    }
}

private actor AVFoundationAudioDriver: AudioEngineDriving {
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()

    init() {
        engine.attach(player)
    }

    func play(samples: [Float], sampleRate: Double) async throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ), let channel = buffer.floatChannelData?[0] else {
            throw AudioPlayerError.invalidBuffer
        }
        buffer.frameLength = buffer.frameCapacity
        channel.update(from: samples, count: samples.count)

        engine.connect(player, to: engine.mainMixerNode, format: format)
        if !engine.isRunning { try engine.start() }
        player.play()
        await withCheckedContinuation { continuation in
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                continuation.resume()
            }
        }
    }

    func stop() async {
        player.stop()
    }

    func rebuild() async throws {
        player.stop()
        engine.stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        configureGraph()
    }

    private func configureGraph() {
        engine.attach(player)
    }
}
