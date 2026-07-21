import Testing
@testable import ChorusCore

@Suite("ModePolicyTests")
struct ModePolicyTests {
    @Test func nightCapsMainAndRejectsSubagent() {
        let config = ChorusConfiguration(mode: .night, muted: false)
        #expect(ModePolicy.admit(priority: .main, requestedVolume: 0.9, configuration: config) == 0.20)
        #expect(ModePolicy.admit(priority: .subagent, requestedVolume: 0.1, configuration: config) == nil)
    }

    @Test func muteRejectsEverything() {
        let config = ChorusConfiguration(mode: .verbose, muted: true)
        #expect(ModePolicy.admit(priority: .main, requestedVolume: 0.8, configuration: config) == nil)
        #expect(ModePolicy.admit(priority: .subagent, requestedVolume: 0.8, configuration: config) == nil)
    }

    @Test(arguments: [ChorusMode.focus, .quiet, .night])
    func focusedModesRejectSubagents(_ mode: ChorusMode) {
        let config = ChorusConfiguration(mode: mode, muted: false)
        #expect(ModePolicy.admit(priority: .subagent, requestedVolume: 0.1, configuration: config) == nil)
        #expect(ModePolicy.admit(priority: .main, requestedVolume: 0.5, configuration: config) != nil)
    }

    @Test func verboseAdmitsSubagentsAndClampsGain() {
        let config = ChorusConfiguration(mode: .verbose, muted: false)
        #expect(ModePolicy.admit(priority: .subagent, requestedVolume: 0.7, configuration: config) == 0.7)
        #expect(ModePolicy.admit(priority: .main, requestedVolume: 1.5, configuration: config) == 1.0)
    }

    @Test func quietCeilingsMainGain() {
        let config = ChorusConfiguration(mode: .quiet, muted: false)
        #expect(ModePolicy.admit(priority: .main, requestedVolume: 1.0, configuration: config) == 0.45)
    }
}
