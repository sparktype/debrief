import Foundation

public struct ChorusPaths: Equatable, Sendable {
    public let home: URL
    public let dataDirectory: URL
    public let cacheDirectory: URL
    public let configURL: URL
    public let modelsDirectory: URL
    public let socketURL: URL
    public let pidURL: URL
    /// Installed executable: `~/.local/bin/debrief`.
    public let executableURL: URL
    public let launchAgentURL: URL
    public let installManifestURL: URL
    public let lastErrorURL: URL

    public static func forHome(_ home: URL) -> ChorusPaths {
        let data = home.appending(path: "Library/Application Support/debrief", directoryHint: .isDirectory)
        let cache = home.appending(path: "Library/Caches/debrief", directoryHint: .isDirectory)
        return ChorusPaths(
            home: home,
            dataDirectory: data,
            cacheDirectory: cache,
            configURL: data.appending(path: "config.json"),
            modelsDirectory: data.appending(path: "models", directoryHint: .isDirectory),
            socketURL: cache.appending(path: "debrief.sock"),
            pidURL: cache.appending(path: "daemon.pid"),
            executableURL: home.appending(path: ".local/bin/debrief"),
            launchAgentURL: home.appending(path: "Library/LaunchAgents/com.debrief.tts.plist"),
            installManifestURL: data.appending(path: "install-manifest.json"),
            lastErrorURL: cache.appending(path: "last-error.json")
        )
    }

    /// Leftover app bundles install and uninstall may delete when the bundle id matches.
    /// `/Applications` is included only for the real user home so a fixture home cannot
    /// remove another install during tests.
    public static func removableApplicationBundles(home: URL) -> [RemovableApplicationBundle] {
        let apps = [
            ("debrief.app", "com.debrief.tts"),
            ("Chorus.app", "com.chorus.tts"),
            ("prompt-recap.app", "com.prompt-recap.tts"),
        ]
        var roots = [home.appending(path: "Applications", directoryHint: .isDirectory)]
        let realHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        if home.standardizedFileURL == realHome {
            roots.append(URL(fileURLWithPath: "/Applications", isDirectory: true))
        }
        return roots.flatMap { root in
            apps.map { name, identifier in
                RemovableApplicationBundle(
                    url: root.appending(path: name, directoryHint: .isDirectory),
                    bundleIdentifier: identifier
                )
            }
        }
    }
}

public struct RemovableApplicationBundle: Equatable, Sendable {
    public let url: URL
    public let bundleIdentifier: String
}
