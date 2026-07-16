import Foundation
import Testing
@testable import ChorusCore

@Suite("ConfigurationCommandTests")
struct ConfigurationCommandTests {
    @Test func allModesPersistUnderTemporaryHome() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        for mode in ChorusMode.allCases {
            let result = try ConfigurationCommands.applyMode(mode.rawValue, home: home)
            #expect(result.mode == mode)
            #expect(ChorusConfiguration.load(from: ChorusPaths.forHome(home).configURL).mode == mode)
        }
    }

    @Test func muteSupportsOnOffToggleAndDefaultToggle() throws {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(try ConfigurationCommands.applyMute("on", home: home).muted)
        #expect(try !ConfigurationCommands.applyMute("off", home: home).muted)
        #expect(try ConfigurationCommands.applyMute("toggle", home: home).muted)
        #expect(try !ConfigurationCommands.applyMute(nil, home: home).muted)
    }

    @Test func invalidModeAndMuteAreRejectedWithoutWriting() {
        let home = temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(throws: ConfigurationCommandError.invalidMode("loud")) {
            try ConfigurationCommands.applyMode("loud", home: home)
        }
        #expect(throws: ConfigurationCommandError.invalidMuteAction("maybe")) {
            try ConfigurationCommands.applyMute("maybe", home: home)
        }
        #expect(!FileManager.default.fileExists(atPath: ChorusPaths.forHome(home).configURL.path))
    }

    private func temporaryHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "chorus-home-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
