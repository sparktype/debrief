import Testing
@testable import DebriefCore

@Suite("ModePolicyTests")
struct ModePolicyTests {
    @Test func nightCapsMainAndRejectsSubagent() {
        let config = DebriefConfiguration(mode: .night, muted: false)
        #expect(ModePolicy.admit(priority: .main, requestedVolume: 0.9, configuration: config) == 0.20)
        #expect(ModePolicy.admit(priority: .subagent, requestedVolume: 0.1, configuration: config) == nil)
    }

    @Test func muteRejectsEverything() {
        let config = DebriefConfiguration(mode: .verbose, muted: true)
        #expect(ModePolicy.admit(priority: .main, requestedVolume: 0.8, configuration: config) == nil)
        #expect(ModePolicy.admit(priority: .subagent, requestedVolume: 0.8, configuration: config) == nil)
    }

    @Test(arguments: [DebriefMode.focus, .quiet, .night])
    func focusedModesRejectSubagents(_ mode: DebriefMode) {
        let config = DebriefConfiguration(mode: mode, muted: false)
        #expect(ModePolicy.admit(priority: .subagent, requestedVolume: 0.1, configuration: config) == nil)
        #expect(ModePolicy.admit(priority: .main, requestedVolume: 0.5, configuration: config) != nil)
    }

    @Test func verboseAdmitsSubagentsAndClampsGain() {
        let config = DebriefConfiguration(mode: .verbose, muted: false)
        #expect(ModePolicy.admit(priority: .subagent, requestedVolume: 0.7, configuration: config) == 0.7)
        #expect(ModePolicy.admit(priority: .main, requestedVolume: 1.5, configuration: config) == 1.0)
    }

    @Test func quietCeilingsMainGain() {
        let config = DebriefConfiguration(mode: .quiet, muted: false)
        #expect(ModePolicy.admit(priority: .main, requestedVolume: 1.0, configuration: config) == 0.45)
    }

    @Test func companionDisabledRejectsCompanionLaneOnly() {
        let config = DebriefConfiguration(mode: .normal, muted: false, companionEnabled: false)
        #expect(
            ModePolicy.admit(
                priority: .main,
                lane: .companion,
                requestedVolume: 0.8,
                configuration: config
            ) == nil
        )
        #expect(
            ModePolicy.admit(
                priority: .main,
                lane: .work,
                requestedVolume: 0.8,
                configuration: config
            ) == 0.8
        )
    }
}
