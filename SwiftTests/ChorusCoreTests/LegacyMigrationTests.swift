import Foundation
import Testing
@testable import ChorusCore

@Suite("LegacyMigrationTests")
struct LegacyMigrationTests {
    @Test func planMigratesOnlyApprovedTTSPreferences() throws {
        let legacyConfig = try JSONSerialization.data(withJSONObject: [
            "autoSpeak": false,
            "voiceMode": "night",
            "volumeCeilings": ["night": 0.15],
            "summaryModel": "external-llm",
            "transcriptPath": "/secret/transcript",
            "metrics": ["enabled": true],
            "history": ["spoken text"],
            "stt": ["enabled": true, "model": "whisper"],
            "supertonicPort": 7777,
        ])
        let voiceMap = try JSONSerialization.data(withJSONObject: [
            "voices": ["planner": "M1", "reviewer": "M3", "invalid": "BAD"],
            "voice_settings": [
                "M1": ["synth_speed": 1.1, "steps": 99],
                "M3": ["synth_speed": 1.0],
                "BAD": ["synth_speed": 5.0],
            ],
            "instructs": ["planner": "do not migrate"],
        ])

        let plan = try LegacyMigration.plan(from: LegacyMigrationSource(
            configuration: legacyConfig,
            voiceMap: voiceMap
        ))

        #expect(plan.configuration.muted)
        #expect(plan.configuration.mode == .night)
        #expect(plan.configuration.volumeCeilings["night"] == 0.15)
        #expect(plan.configuration.categoryVoices == ["planner": "M1", "reviewer": "M3"])
        #expect(plan.configuration.voiceSpeeds == ["M1": 1.1, "M3": 1.0])
        let encoded = String(decoding: try JSONEncoder().encode(plan.configuration), as: UTF8.self)
        for forbidden in ["summaryModel", "transcript", "metrics", "history", "stt", "whisper", "Port", "instruct"] {
            #expect(!encoded.localizedCaseInsensitiveContains(forbidden))
        }
    }

    @Test func applyUnloadsOnlyKnownLabelsAfterHealthPasses() async throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = RecordingLegacyServiceRunner()
        let plan = MigrationPlan(configuration: .default)
        let launchAgents = home.appending(path: "Library/LaunchAgents")
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        for label in plan.legacyLaunchAgentLabels {
            try Data("legacy".utf8).write(to: launchAgents.appending(path: "\(label).plist"))
        }

        await #expect(throws: LegacyMigrationError.healthCheckFailed) {
            try await LegacyMigration.apply(plan, home: home, afterHealthCheck: false, runner: runner)
        }
        #expect(await runner.labels.isEmpty)

        try await LegacyMigration.apply(plan, home: home, afterHealthCheck: true, runner: runner)
        #expect(await runner.labels == ["io.chorus.server", "com.voice-persona.tts-server"])
        for label in plan.legacyLaunchAgentLabels {
            #expect(!FileManager.default.fileExists(
                atPath: launchAgents.appending(path: "\(label).plist").path
            ))
        }
    }

    private func temporaryHome() -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "chorus-migration-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor RecordingLegacyServiceRunner: LegacyServiceRunning {
    private(set) var labels: [String] = []
    func unload(label: String) async throws { labels.append(label) }
}
