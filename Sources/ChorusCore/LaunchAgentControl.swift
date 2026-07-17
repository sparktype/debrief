// LaunchAgent 라벨·disable/enable/bootout (메뉴 종료 시 KeepAlive 재기동 방지)
import Darwin
import Foundation

/// Controls the installed Chorus LaunchAgent (`com.chorus.tts`).
///
/// **Quit must not wait on `bootout` from inside the job.** `launchctl bootout`
/// waits for the target process to exit; if that process is us, we deadlock.
/// Disable first (non-blocking for the running job), stop the service, exit;
/// KeepAlive will not relaunch a disabled service. Install re-enables.
public enum LaunchAgentControl: Sendable {
    public static let label = "com.chorus.tts"

    public static func domain(userID: UInt32 = getuid()) -> String {
        "gui/\(userID)"
    }

    public static func serviceTarget(userID: UInt32 = getuid()) -> String {
        "\(domain(userID: userID))/\(label)"
    }

    public static func bootoutArguments(userID: UInt32 = getuid()) -> [String] {
        ["bootout", serviceTarget(userID: userID)]
    }

    public static func disableArguments(userID: UInt32 = getuid()) -> [String] {
        ["disable", serviceTarget(userID: userID)]
    }

    public static func enableArguments(userID: UInt32 = getuid()) -> [String] {
        ["enable", serviceTarget(userID: userID)]
    }

    /// Marks the agent disabled so KeepAlive will not relaunch after exit.
    /// Safe to await from inside the running job (unlike `bootout`).
    public static func disable(
        userID: UInt32 = getuid(),
        launchctl: any LaunchctlRunning = ProcessLaunchctlRunner()
    ) async throws {
        try await launchctl.run(arguments: disableArguments(userID: userID), allowFailure: true)
    }

    /// Re-enables the agent so bootstrap/install can load it again.
    public static func enable(
        userID: UInt32 = getuid(),
        launchctl: any LaunchctlRunning = ProcessLaunchctlRunner()
    ) async throws {
        try await launchctl.run(arguments: enableArguments(userID: userID), allowFailure: true)
    }

    /// Unloads the agent. Do **not** await this from inside the same job — deadlock.
    public static func bootout(
        userID: UInt32 = getuid(),
        launchctl: any LaunchctlRunning = ProcessLaunchctlRunner()
    ) async throws {
        try await launchctl.run(arguments: bootoutArguments(userID: userID), allowFailure: true)
    }

    /// Starts `launchctl bootout` without waiting (best-effort cleanup after disable).
    public static func bootoutDetached(userID: UInt32 = getuid()) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = bootoutArguments(userID: userID)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
