import ChorusCore
import Foundation

do {
    let command = try ChorusCommand.parse(Array(CommandLine.arguments.dropFirst()))
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
    default:
        print("chorus: \(command) is not implemented yet")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n\n\(ChorusCommand.usageText)\n".utf8))
    exit(64)
}
