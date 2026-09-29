import CoreFoundation
import Foundation

public struct LegacyMigrationSource: Sendable {
    public let configuration: Data?
    public let voiceMap: Data?

    public init(configuration: Data?, voiceMap: Data?) {
        self.configuration = configuration
        self.voiceMap = voiceMap
    }
}

public struct MigrationPlan: Equatable, Sendable {
    public let configuration: ChorusConfiguration
    public let legacyLaunchAgentLabels: [String]

    public init(
        configuration: ChorusConfiguration,
        legacyLaunchAgentLabels: [String] = LegacyMigration.knownLaunchAgentLabels
    ) {
        self.configuration = configuration
        self.legacyLaunchAgentLabels = legacyLaunchAgentLabels
    }
}

public enum LegacyMigrationError: Error, Equatable, Sendable {
    case invalidJSON
    case healthCheckFailed
}

public protocol LegacyServiceRunning: Sendable {
    func unload(label: String) async throws
}

public enum LegacyMigration {
    public static let knownLaunchAgentLabels = [
        "io.chorus.server",
        "com.voice-persona.tts-server",
    ]
    private static let allowedCategories = Set([
        "reviewer", "planner", "builder", "tester", "explorer",
        "optimizer", "guardian", "ops", "specialist", "default",
    ])

    public static func plan(from source: LegacyMigrationSource) throws -> MigrationPlan {
        let config = try object(from: source.configuration)
        let voiceMap = try object(from: source.voiceMap)
        let autoSpeak = config["autoSpeak"] as? Bool ?? true
        let modeValue = (config["voiceMode"] as? String) ?? (config["mode"] as? String)
        let mode = modeValue.flatMap(ChorusMode.init(rawValue:)) ?? .normal
        var ceilings = ChorusConfiguration.defaultVolumeCeilings
        if let legacyCeilings = config["volumeCeilings"] as? [String: Any] {
            for (key, value) in legacyCeilings {
                guard ChorusMode(rawValue: key) != nil,
                      let number = value as? NSNumber,
                      !isBoolean(number),
                      (0...1).contains(number.doubleValue) else { continue }
                ceilings[key] = number.doubleValue
            }
        }

        var voices: [String: String] = [:]
        if let legacyVoices = voiceMap["voices"] as? [String: Any] {
            for (category, value) in legacyVoices {
                guard allowedCategories.contains(category),
                      let voice = value as? String,
                      VoiceCatalog.allowedVoiceIDs.contains(voice) else { continue }
                voices[category] = voice
            }
        }
        var speeds: [String: Double] = [:]
        if let settings = voiceMap["voice_settings"] as? [String: Any] {
            for (voice, raw) in settings {
                guard VoiceCatalog.allowedVoiceIDs.contains(voice),
                      let values = raw as? [String: Any],
                      let number = values["synth_speed"] as? NSNumber,
                      !isBoolean(number),
                      (0.7...2.0).contains(number.doubleValue) else { continue }
                speeds[voice] = number.doubleValue
            }
        }
        return MigrationPlan(configuration: ChorusConfiguration(
            mode: mode,
            muted: !autoSpeak,
            volumeCeilings: ceilings,
            categoryVoices: voices,
            voiceSpeeds: speeds
        ))
    }

    public static func apply<Runner: LegacyServiceRunning>(
        _ plan: MigrationPlan,
        home: URL,
        afterHealthCheck healthy: Bool,
        runner: Runner
    ) async throws {
        guard healthy else { throw LegacyMigrationError.healthCheckFailed }
        try plan.configuration.save(to: ChorusPaths.forHome(home).configURL)
        for label in plan.legacyLaunchAgentLabels {
            try await runner.unload(label: label)
            let plist = home.appending(path: "Library/LaunchAgents/\(label).plist")
            if FileManager.default.fileExists(atPath: plist.path) {
                try FileManager.default.removeItem(at: plist)
            }
        }
    }

    private static func object(from data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LegacyMigrationError.invalidJSON
        }
        return value
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
