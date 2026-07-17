import ChorusCore
import Darwin
import Foundation

let command: ChorusCommand
do {
    command = try ChorusCommand.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n\n\(ChorusCommand.usageText)\n".utf8))
    exit(64)
}

let home = ProcessInfo.processInfo.environment["CHORUS_HOME"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? FileManager.default.homeDirectoryForCurrentUser

do {
    switch command {
    case .help:
        print(ChorusCommand.usageText)
    case let .install(codex, claude, repair):
        let paths = ChorusPaths.forHome(home)
        let hosts = selectedHosts(codex: codex, claude: claude)
        let sourceExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var runtime = RuntimeInstaller(
            home: home,
            sourceExecutable: sourceExecutable,
            modelInstaller: ModelInstaller(
                modelsDirectory: paths.modelsDirectory,
                manifest: .supertonic3,
                downloader: URLSessionModelDownloader()
            ),
            launchctl: ProcessLaunchctlRunner()
        )
        runtime.applicationIconPNG = loadApplicationIconPNG(startingAt: sourceExecutable)
        let result = try await runtime.install(hosts: hosts, repair: repair)
        print("installed: \(hosts.map(\.rawValue).sorted().joined(separator: ","))")
        print("app: \(paths.applicationBundleURL.path)")
        if result.codexReviewRequired {
            print("Codex에서 /hooks를 열어 Chorus hook을 검토하고 신뢰하세요.")
        }
        printPreservedFiles(result.preservedModifiedFiles)
    case let .uninstall(codex, claude):
        let paths = ChorusPaths.forHome(home)
        let hosts = selectedHosts(codex: codex, claude: claude)
        let runtime = RuntimeInstaller(
            home: home,
            sourceExecutable: paths.executableURL,
            modelInstaller: ModelInstaller(
                modelsDirectory: paths.modelsDirectory,
                manifest: .supertonic3,
                downloader: URLSessionModelDownloader()
            ),
            launchctl: ProcessLaunchctlRunner()
        )
        let result = try await runtime.uninstall(hosts: hosts)
        print("uninstalled: \(hosts.map(\.rawValue).sorted().joined(separator: ","))")
        printPreservedFiles(result.preservedModifiedFiles)
    case let .hook(sourceValue):
        guard let source = HostSource(rawValue: sourceValue) else {
            throw CommandError.usage("--source must be codex or claude")
        }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let output = await HookCommandRunner.run(input: input, source: source, home: home)
        FileHandle.standardOutput.write(output)
    case .menubar:
        // Blocks on AppKit run loop. Status item is created before any TTS await.
        await MainActor.run {
            MenuBarApp.runBlocking(home: home)
        }
    }
} catch {
    try? Diagnostics(home: home).recordError(
        component: "app",
        code: "command_failed",
        message: "command failed; open Chorus.app or reinstall"
    )
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

private func selectedHosts(codex: Bool, claude: Bool) -> Set<HostSource> {
    if !codex, !claude { return Set(HostSource.allCases) }
    var hosts = Set<HostSource>()
    if codex { hosts.insert(.codex) }
    if claude { hosts.insert(.claude) }
    return hosts
}

/// Walks parents of the running binary for `icon.png` (repo root or package).
private func loadApplicationIconPNG(startingAt executable: URL) -> Data? {
    var directory = executable.deletingLastPathComponent()
    for _ in 0..<8 {
        let candidate = directory.appending(path: "icon.png")
        if let data = try? Data(contentsOf: candidate), !data.isEmpty {
            return data
        }
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { break }
        directory = parent
    }
    return nil
}

private func printPreservedFiles(_ paths: [String]) {
    for path in paths {
        print("preserved modified file: \(path)")
    }
}
