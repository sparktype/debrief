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

do {
    let home = ProcessInfo.processInfo.environment["CHORUS_HOME"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser
    switch command {
    case .help:
        print(ChorusCommand.usageText)
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
        let paths = ChorusPaths.forHome(home)
        let server = try UnixSocketServer(socketURL: paths.socketURL)
        let modelDirectory = paths.modelsDirectory.appending(
            path: "supertonic-3/current",
            directoryHint: .isDirectory
        )
        let daemon = ChorusDaemon(
            source: server,
            queue: SpeechQueue(),
            backend: try SupertonicEngine(modelDirectory: modelDirectory),
            audio: AudioPlayer(),
            configuration: { ChorusConfiguration.load(from: paths.configURL) }
        )
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM)
        let interruption = DispatchSource.makeSignalSource(signal: SIGINT)
        termination.setEventHandler { Task { await daemon.shutdown() } }
        interruption.setEventHandler { Task { await daemon.shutdown() } }
        termination.resume()
        interruption.resume()
        defer {
            termination.cancel()
            interruption.cancel()
        }
        try await daemon.run()
    case let .speak(text, voice, speed, volume):
        try await DirectSpeechCommand.submit(
            text: text,
            voice: voice,
            speed: speed,
            volume: volume,
            home: home
        )
    default:
        print("chorus: \(command) is not implemented yet")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
