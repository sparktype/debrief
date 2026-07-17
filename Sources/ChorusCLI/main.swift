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
        let runtime = RuntimeInstaller(
            home: home,
            sourceExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath(),
            modelInstaller: ModelInstaller(
                modelsDirectory: paths.modelsDirectory,
                manifest: .supertonic3,
                downloader: URLSessionModelDownloader()
            ),
            launchctl: ProcessLaunchctlRunner()
        )
        let result = try await runtime.install(hosts: hosts, repair: repair)
        print("installed: \(hosts.map(\.rawValue).sorted().joined(separator: ","))")
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
    case let .mode(value):
        let configuration = try ConfigurationCommands.applyMode(value, home: home)
        print("mode: \(configuration.mode.rawValue)")
    case let .mute(value):
        let configuration = try ConfigurationCommands.applyMute(value, home: home)
        print("muted: \(configuration.muted)")
    case let .hook(sourceValue):
        guard let source = HostSource(rawValue: sourceValue) else {
            throw CommandError.usage("--source must be codex or claude")
        }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let output = await HookCommandRunner.run(input: input, source: source, home: home)
        FileHandle.standardOutput.write(output)
    case .daemon:
        let service = ResidentService(
            home: home,
            backendFactory: { try SupertonicEngine(modelDirectory: $0) },
            audioFactory: { AudioPlayer() }
        )
        try await service.start()
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM)
        let interruption = DispatchSource.makeSignalSource(signal: SIGINT)
        termination.setEventHandler { Task { await service.stop() } }
        interruption.setEventHandler { Task { await service.stop() } }
        termination.resume()
        interruption.resume()
        defer {
            termination.cancel()
            interruption.cancel()
        }
        await service.waitUntilStopped()
        if let error = await service.consumeRunFailure() {
            throw error
        }
    case .menubar:
        // AppKit NSStatusItem resident; blocks until SIGTERM/SIGINT terminate.
        await MenuBarApp.run(home: home)
    case let .speak(text, voice, speed, volume):
        try await DirectSpeechCommand.submit(
            text: text,
            voice: voice,
            speed: speed,
            volume: volume,
            home: home
        )
    case .status:
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(Diagnostics(home: home).status()))
        print()
    case .doctor:
        let findings = Diagnostics(home: home).doctor()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(findings))
        print()
        if findings.contains(where: { !$0.ok }) { exit(1) }
    }
} catch {
    try? Diagnostics(home: home).recordError(
        component: "cli",
        code: "command_failed",
        message: "command failed; run chorus doctor"
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

private func printPreservedFiles(_ paths: [String]) {
    for path in paths {
        print("preserved modified file: \(path)")
    }
}
