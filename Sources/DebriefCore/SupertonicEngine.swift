import Foundation
import OnnxRuntimeBindings

// Inference flow adapted from Supertone Inc.'s MIT-licensed Supertonic Swift example.

public enum SupertonicError: Error, Equatable, Sendable {
    case invalidModelConfiguration
    case invalidText
    case invalidVoice
    case invalidSpeed
    case invalidVoiceStyle
    case missingOutput(String)
    case invalidTensorData
}

private struct SupertonicConfiguration: Decodable {
    struct Autoencoder: Decodable {
        let sampleRate: Int
        let baseChunkSize: Int

        enum CodingKeys: String, CodingKey {
            case sampleRate = "sample_rate"
            case baseChunkSize = "base_chunk_size"
        }
    }

    struct TextToLatent: Decodable {
        let chunkCompressFactor: Int
        let latentDim: Int

        enum CodingKeys: String, CodingKey {
            case chunkCompressFactor = "chunk_compress_factor"
            case latentDim = "latent_dim"
        }
    }

    let ae: Autoencoder
    let ttl: TextToLatent
}

private struct SupertonicVoiceFile: Decodable {
    struct Component: Decodable {
        let data: [[[Float]]]
        let dims: [Int]
    }

    let styleTTL: Component
    let styleDP: Component

    enum CodingKeys: String, CodingKey {
        case styleTTL = "style_ttl"
        case styleDP = "style_dp"
    }
}

private struct SupertonicStyle {
    let ttl: ORTValue
    let dp: ORTValue
}

private final class SupertonicTextProcessor {
    private let indexer: [Int64]

    init(url: URL) throws {
        indexer = try JSONDecoder().decode([Int64].self, from: Data(contentsOf: url))
    }

    func encode(_ text: String) throws -> (ids: [Int64], mask: [Float], count: Int) {
        let processed = try preprocess(text)
        let scalars = processed.unicodeScalars.map { Int($0.value) }
        guard !scalars.isEmpty else { throw SupertonicError.invalidText }
        let ids = scalars.map { scalar in
            scalar < indexer.count ? indexer[scalar] : -1
        }
        return (ids, SupertonicTensor.lengthMask([ids.count]), ids.count)
    }

    private func preprocess(_ input: String) throws -> String {
        var text = input.decomposedStringWithCompatibilityMapping
        text = text.unicodeScalars
            .filter { !Self.isEmoji($0.value) }
            .map(String.init)
            .joined()

        let replacements = [
            "–": "-", "‑": "-", "—": "-", "_": " ",
            "“": "\"", "”": "\"", "‘": "'", "’": "'", "´": "'", "`": "'",
            "[": " ", "]": " ", "|": " ", "/": " ", "#": " ", "→": " ", "←": " ",
            "@": " at ", "e.g.,": "for example, ", "i.e.,": "that is, ",
        ]
        for (source, destination) in replacements {
            text = text.replacingOccurrences(of: source, with: destination)
        }
        for symbol in ["♥", "☆", "♡", "©", "\\"] {
            text = text.replacingOccurrences(of: symbol, with: "")
        }
        for punctuation in [",", ".", "!", "?", ";", ":", "'"] {
            text = text.replacingOccurrences(of: " \(punctuation)", with: punctuation)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SupertonicError.invalidText }
        if text.range(of: "[.!?;:,'\")\\]}…。」』】〉》›»]$", options: .regularExpression) == nil {
            text += "."
        }
        return "<ko>\(text)</ko>"
    }

    private static func isEmoji(_ value: UInt32) -> Bool {
        (0x1F300...0x1FAFF).contains(value)
            || (0x2600...0x27BF).contains(value)
            || (0x1F1E6...0x1F1FF).contains(value)
    }
}

public actor SupertonicEngine: TTSBackend {
    private static let denoisingSteps = 8
    private static let sampleRate = 44_100

    private let voiceDirectory: URL
    private let configuration: SupertonicConfiguration
    private let textProcessor: SupertonicTextProcessor
    private let environment: ORTEnv
    private let durationPredictor: ORTSession
    private let textEncoder: ORTSession
    private let vectorEstimator: ORTSession
    private let vocoder: ORTSession
    private var styles: [String: SupertonicStyle] = [:]

    public init(modelDirectory: URL) throws {
        voiceDirectory = modelDirectory.appending(path: "voice_styles", directoryHint: .isDirectory)
        let onnxDirectory = modelDirectory.appending(path: "onnx", directoryHint: .isDirectory)
        configuration = try JSONDecoder().decode(
            SupertonicConfiguration.self,
            from: Data(contentsOf: onnxDirectory.appending(path: "tts.json"))
        )
        guard configuration.ae.sampleRate == Self.sampleRate,
              configuration.ae.baseChunkSize > 0,
              configuration.ttl.chunkCompressFactor > 0,
              configuration.ttl.latentDim > 0 else {
            throw SupertonicError.invalidModelConfiguration
        }
        textProcessor = try SupertonicTextProcessor(
            url: onnxDirectory.appending(path: "unicode_indexer.json")
        )

        environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        durationPredictor = try ORTSession(
            env: environment,
            modelPath: onnxDirectory.appending(path: "duration_predictor.onnx").path,
            sessionOptions: options
        )
        textEncoder = try ORTSession(
            env: environment,
            modelPath: onnxDirectory.appending(path: "text_encoder.onnx").path,
            sessionOptions: options
        )
        vectorEstimator = try ORTSession(
            env: environment,
            modelPath: onnxDirectory.appending(path: "vector_estimator.onnx").path,
            sessionOptions: options
        )
        vocoder = try ORTSession(
            env: environment,
            modelPath: onnxDirectory.appending(path: "vocoder.onnx").path,
            sessionOptions: options
        )
    }

    public func synthesize(text: String, voice: String, speed: Double) async throws -> PCMBuffer {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SupertonicError.invalidText
        }
        guard VoiceCatalog.allowedVoiceIDs.contains(voice) else {
            throw SupertonicError.invalidVoice
        }
        guard speed.isFinite, (0.7...2.0).contains(speed) else {
            throw SupertonicError.invalidSpeed
        }

        let style = try style(for: voice)
        let chunks = SupertonicTensor.splitText(text, maxLength: 120)
        var audioChunks: [[Float]] = []
        for chunk in chunks where !chunk.isEmpty {
            audioChunks.append(try infer(chunk, style: style, speed: Float(speed)))
        }
        guard !audioChunks.isEmpty else { throw SupertonicError.invalidText }
        let samples = SupertonicTensor.concatenate(
            audioChunks,
            silenceSamples: Int(0.3 * Double(Self.sampleRate))
        )
        return PCMBuffer(sampleRate: Double(Self.sampleRate), channels: 1, samples: samples)
    }

    private func style(for voice: String) throws -> SupertonicStyle {
        if let cached = styles[voice] { return cached }
        let url = voiceDirectory.appending(path: "\(voice).json")
        let file = try JSONDecoder().decode(SupertonicVoiceFile.self, from: Data(contentsOf: url))
        let ttl = try Self.styleValue(file.styleTTL)
        let dp = try Self.styleValue(file.styleDP)
        let style = SupertonicStyle(ttl: ttl, dp: dp)
        styles[voice] = style
        return style
    }

    private func infer(_ text: String, style: SupertonicStyle, speed: Float) throws -> [Float] {
        let encoded = try textProcessor.encode(text)
        let textIDs = try Self.value(encoded.ids, type: .int64, shape: [1, encoded.count])
        let textMask = try Self.value(encoded.mask, type: .float, shape: [1, 1, encoded.count])

        let durationOutputs = try durationPredictor.run(
            withInputs: ["text_ids": textIDs, "style_dp": style.dp, "text_mask": textMask],
            outputNames: ["duration"],
            runOptions: nil
        )
        guard let durationValue = durationOutputs["duration"] else {
            throw SupertonicError.missingOutput("duration")
        }
        let durationData = try durationValue.tensorData() as Data
        guard let predictedDuration = SupertonicTensor.floatSamples(from: durationData).first else {
            throw SupertonicError.invalidTensorData
        }
        let duration = predictedDuration / speed
        guard duration.isFinite, duration > 0 else { throw SupertonicError.invalidTensorData }

        let textOutputs = try textEncoder.run(
            withInputs: ["text_ids": textIDs, "style_ttl": style.ttl, "text_mask": textMask],
            outputNames: ["text_emb"],
            runOptions: nil
        )
        guard let textEmbedding = textOutputs["text_emb"] else {
            throw SupertonicError.missingOutput("text_emb")
        }

        let latent = Self.noisyLatent(duration: duration, configuration: configuration)
        var noise = latent.values
        let totalStep = try Self.value(
            [Float(Self.denoisingSteps)],
            type: .float,
            shape: [1]
        )
        let noiseShape = [1, latent.dimensions, latent.length]
        let mask = try Self.value(latent.mask, type: .float, shape: [1, 1, latent.length])

        for step in 0..<Self.denoisingSteps {
            let currentStep = try Self.value([Float(step)], type: .float, shape: [1])
            let noisyValue = try Self.value(noise, type: .float, shape: noiseShape)
            let outputs = try vectorEstimator.run(
                withInputs: [
                    "noisy_latent": noisyValue,
                    "text_emb": textEmbedding,
                    "style_ttl": style.ttl,
                    "latent_mask": mask,
                    "text_mask": textMask,
                    "current_step": currentStep,
                    "total_step": totalStep,
                ],
                outputNames: ["denoised_latent"],
                runOptions: nil
            )
            guard let denoised = outputs["denoised_latent"] else {
                throw SupertonicError.missingOutput("denoised_latent")
            }
            noise = SupertonicTensor.floatSamples(from: try denoised.tensorData() as Data)
            guard noise.count == latent.values.count else {
                throw SupertonicError.invalidTensorData
            }
        }

        let latentValue = try Self.value(noise, type: .float, shape: noiseShape)
        let outputs = try vocoder.run(
            withInputs: ["latent": latentValue],
            outputNames: ["wav_tts"],
            runOptions: nil
        )
        guard let waveform = outputs["wav_tts"] else {
            throw SupertonicError.missingOutput("wav_tts")
        }
        let samples = SupertonicTensor.floatSamples(from: try waveform.tensorData() as Data)
        let expectedCount = Int(Float(Self.sampleRate) * duration)
        guard !samples.isEmpty, expectedCount > 0 else { throw SupertonicError.invalidTensorData }
        return Array(samples.prefix(expectedCount))
    }

    private static func styleValue(_ component: SupertonicVoiceFile.Component) throws -> ORTValue {
        guard component.dims.count == 3,
              component.dims[0] == 1,
              component.dims.allSatisfy({ $0 > 0 }) else {
            throw SupertonicError.invalidVoiceStyle
        }
        let flattened = component.data.flatMap { $0.flatMap { $0 } }
        guard flattened.count == component.dims.reduce(1, *) else {
            throw SupertonicError.invalidVoiceStyle
        }
        return try value(flattened, type: .float, shape: component.dims)
    }

    private static func value<Element>(
        _ elements: [Element],
        type: ORTTensorElementDataType,
        shape: [Int]
    ) throws -> ORTValue {
        let expectedCount = shape.reduce(1, *)
        guard !elements.isEmpty, expectedCount == elements.count else {
            throw SupertonicError.invalidTensorData
        }
        let data = elements.withUnsafeBytes { bytes in
            NSMutableData(bytes: bytes.baseAddress, length: bytes.count)
        }
        return try ORTValue(
            tensorData: data,
            elementType: type,
            shape: shape.map(NSNumber.init(value:))
        )
    }

    private static func noisyLatent(
        duration: Float,
        configuration: SupertonicConfiguration
    ) -> (values: [Float], mask: [Float], dimensions: Int, length: Int) {
        let chunkSize = configuration.ae.baseChunkSize * configuration.ttl.chunkCompressFactor
        let waveformLength = Int(duration * Float(configuration.ae.sampleRate))
        let latentLength = max(1, (waveformLength + chunkSize - 1) / chunkSize)
        let latentDimensions = configuration.ttl.latentDim * configuration.ttl.chunkCompressFactor
        let mask = SupertonicTensor.lengthMask(
            [(waveformLength + chunkSize - 1) / chunkSize],
            maxLength: latentLength
        )
        var values = [Float](repeating: 0, count: latentDimensions * latentLength)
        for index in values.indices {
            let uniform1 = Float.random(in: 0.0001...1)
            let uniform2 = Float.random(in: 0...1)
            values[index] = sqrt(-2 * log(uniform1)) * cos(2 * .pi * uniform2)
                * mask[index % latentLength]
        }
        return (values, mask, latentDimensions, latentLength)
    }
}
