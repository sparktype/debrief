import Darwin
import Foundation

/// The real path of the running binary. `CommandLine.arguments[0]` is only the
/// literal command a shell resolved via `PATH` — not an absolute path — so this
/// must not be derived from argv.
public func currentExecutableURL() -> URL {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [Int8](repeating: 0, count: Int(size))
    _NSGetExecutablePath(&buffer, &size)
    let path = buffer.withUnsafeBufferPointer { pointer in
        String(decoding: pointer.prefix(while: { $0 != 0 }).map { UInt8($0) }, as: UTF8.self)
    }
    return URL(fileURLWithPath: path).resolvingSymlinksInPath()
}

public struct DebriefPaths: Equatable, Sendable {
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
    /// Session id → companion voice. Shared by hooks and the MCP server.
    public let sessionVoicesURL: URL

    public static func forHome(_ home: URL) -> DebriefPaths {
        let data = home.appending(path: "Library/Application Support/debrief", directoryHint: .isDirectory)
        let cache = home.appending(path: "Library/Caches/debrief", directoryHint: .isDirectory)
        return DebriefPaths(
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
            lastErrorURL: cache.appending(path: "last-error.json"),
            sessionVoicesURL: data.appending(path: "session-voices.json")
        )
    }
}
