import ChorusCore
import Foundation

do {
    let command = try ChorusCommand.parse(Array(CommandLine.arguments.dropFirst()))
    switch command {
    case .help:
        print(ChorusCommand.usageText)
    default:
        print("chorus: \(command) is not implemented yet")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n\n\(ChorusCommand.usageText)\n".utf8))
    exit(64)
}
