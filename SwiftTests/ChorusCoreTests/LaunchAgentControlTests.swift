import Darwin
import Foundation
import Testing
@testable import ChorusCore

@Suite("LaunchAgentControlTests")
struct LaunchAgentControlTests {
    @Test func bootoutArgumentsTargetGuiDomainAndLabel() {
        let args = LaunchAgentControl.bootoutArguments(userID: 501)
        #expect(args == ["bootout", "gui/501/com.chorus.tts"])
        #expect(LaunchAgentControl.label == "com.chorus.tts")
    }

    @Test func bootoutInvokesLaunchctlWithAllowFailure() async throws {
        let runner = RecordingLaunchctl()
        try await LaunchAgentControl.bootout(userID: 42, launchctl: runner)
        let calls = await runner.calls
        #expect(calls.count == 1)
        #expect(calls[0].arguments == ["bootout", "gui/42/com.chorus.tts"])
        #expect(calls[0].allowFailure == true)
    }
}

private actor RecordingLaunchctl: LaunchctlRunning {
    private(set) var calls: [(arguments: [String], allowFailure: Bool)] = []

    func run(arguments: [String], allowFailure: Bool) async throws {
        calls.append((arguments, allowFailure))
    }
}
