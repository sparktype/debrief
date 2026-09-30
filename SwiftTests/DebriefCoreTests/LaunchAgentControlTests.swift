import Darwin
import Foundation
import Testing
@testable import DebriefCore

@Suite("LaunchAgentControlTests")
struct LaunchAgentControlTests {
    @Test func serviceTargetAndBootoutArguments() {
        #expect(LaunchAgentControl.label == "com.debrief.tts")
        #expect(LaunchAgentControl.serviceTarget(userID: 501) == "gui/501/com.debrief.tts")
        #expect(LaunchAgentControl.bootoutArguments(userID: 501) == ["bootout", "gui/501/com.debrief.tts"])
        #expect(LaunchAgentControl.disableArguments(userID: 501) == ["disable", "gui/501/com.debrief.tts"])
        #expect(LaunchAgentControl.enableArguments(userID: 501) == ["enable", "gui/501/com.debrief.tts"])
    }

    @Test func disableInvokesLaunchctlWithAllowFailure() async throws {
        let runner = RecordingLaunchctl()
        try await LaunchAgentControl.disable(userID: 42, launchctl: runner)
        let calls = await runner.calls
        #expect(calls.count == 1)
        #expect(calls[0].arguments == ["disable", "gui/42/com.debrief.tts"])
        #expect(calls[0].allowFailure == true)
    }

    @Test func enableInvokesLaunchctlWithAllowFailure() async throws {
        let runner = RecordingLaunchctl()
        try await LaunchAgentControl.enable(userID: 42, launchctl: runner)
        let calls = await runner.calls
        #expect(calls.count == 1)
        #expect(calls[0].arguments == ["enable", "gui/42/com.debrief.tts"])
        #expect(calls[0].allowFailure == true)
    }
}

private actor RecordingLaunchctl: LaunchctlRunning {
    private(set) var calls: [(arguments: [String], allowFailure: Bool)] = []

    func run(arguments: [String], allowFailure: Bool) async throws {
        calls.append((arguments, allowFailure))
    }
}
