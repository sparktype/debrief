import Foundation

public struct ChorusPaths: Equatable, Sendable {
    public let home: URL
    public let dataDirectory: URL
    public let cacheDirectory: URL
    public let configURL: URL
    public let modelsDirectory: URL
    public let socketURL: URL
    public let pidURL: URL
    public let executableURL: URL
    public let launchAgentURL: URL
    public let installManifestURL: URL
    public let lastErrorURL: URL

    public static func forHome(_ home: URL) -> ChorusPaths {
        let data = home.appending(path: "Library/Application Support/Chorus", directoryHint: .isDirectory)
        let cache = home.appending(path: "Library/Caches/Chorus", directoryHint: .isDirectory)
        return ChorusPaths(
            home: home,
            dataDirectory: data,
            cacheDirectory: cache,
            configURL: data.appending(path: "config.json"),
            modelsDirectory: data.appending(path: "models", directoryHint: .isDirectory),
            socketURL: cache.appending(path: "chorus.sock"),
            pidURL: cache.appending(path: "daemon.pid"),
            executableURL: home.appending(path: ".local/bin/chorus"),
            launchAgentURL: home.appending(path: "Library/LaunchAgents/com.chorus.tts.plist"),
            installManifestURL: data.appending(path: "install-manifest.json"),
            lastErrorURL: cache.appending(path: "last-error.json")
        )
    }
}
