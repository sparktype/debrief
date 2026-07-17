// LaunchAgent 라벨·bootout 인자 (메뉴 종료 시 KeepAlive 재기동 방지)
import Darwin
import Foundation

/// Controls the installed Chorus LaunchAgent (`com.chorus.tts`).
public enum LaunchAgentControl: Sendable {
    public static let label = "com.chorus.tts"

    /// `launchctl bootout` arguments for the current (or given) user domain.
    public static func bootoutArguments(userID: UInt32 = getuid()) -> [String] {
        ["bootout", "gui/\(userID)/\(label)"]
    }

    /// Unloads the LaunchAgent so KeepAlive does not relaunch after Quit.
    public static func bootout(
        userID: UInt32 = getuid(),
        launchctl: any LaunchctlRunning = ProcessLaunchctlRunner()
    ) async throws {
        try await launchctl.run(arguments: bootoutArguments(userID: userID), allowFailure: true)
    }
}
