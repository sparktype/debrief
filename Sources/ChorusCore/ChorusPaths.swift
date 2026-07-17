import Foundation

public struct ChorusPaths: Equatable, Sendable {
    public let home: URL
    public let dataDirectory: URL
    public let cacheDirectory: URL
    public let configURL: URL
    public let modelsDirectory: URL
    public let socketURL: URL
    public let pidURL: URL
    /// `Chorus.app` under Applications (user or system).
    public let applicationBundleURL: URL
    /// `Contents/MacOS/chorus` inside the app bundle.
    public let executableURL: URL
    /// Legacy path formerly used as a CLI symlink; cleaned up on install/uninstall.
    public let legacyCLISymlinkURL: URL
    public let launchAgentURL: URL
    public let installManifestURL: URL
    public let lastErrorURL: URL

    public static func forHome(_ home: URL) -> ChorusPaths {
        let data = home.appending(path: "Library/Application Support/Chorus", directoryHint: .isDirectory)
        let cache = home.appending(path: "Library/Caches/Chorus", directoryHint: .isDirectory)
        let applications = preferredApplicationsDirectory(home: home)
        let appBundle = AppBundleInstaller.bundleURL(applicationsDirectory: applications)
        return ChorusPaths(
            home: home,
            dataDirectory: data,
            cacheDirectory: cache,
            configURL: data.appending(path: "config.json"),
            modelsDirectory: data.appending(path: "models", directoryHint: .isDirectory),
            socketURL: cache.appending(path: "chorus.sock"),
            pidURL: cache.appending(path: "daemon.pid"),
            applicationBundleURL: appBundle,
            executableURL: AppBundleInstaller.executableURL(appBundle: appBundle),
            legacyCLISymlinkURL: home.appending(path: ".local/bin/chorus"),
            launchAgentURL: home.appending(path: "Library/LaunchAgents/com.chorus.tts.plist"),
            installManifestURL: data.appending(path: "install-manifest.json"),
            lastErrorURL: cache.appending(path: "last-error.json")
        )
    }

    /// Install location for `Chorus.app`.
    ///
    /// Uses `/Applications` only for the real user home when writable; otherwise
    /// `~/Applications` (and always a home-relative Applications for CHORUS_HOME tests).
    public static func preferredApplicationsDirectory(home: URL) -> URL {
        let realHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        if home.standardizedFileURL == realHome {
            let systemApps = URL(fileURLWithPath: "/Applications", isDirectory: true)
            if FileManager.default.isWritableFile(atPath: systemApps.path) {
                return systemApps
            }
        }
        return home.appending(path: "Applications", directoryHint: .isDirectory)
    }
}
