// CLI 서브커맨드 파싱 (Core — 테스트 가능)
import Foundation

public enum CommandError: Error, Equatable, CustomStringConvertible {
    case usage(String)

    public var description: String {
        switch self {
        case let .usage(message): message
        }
    }
}

public enum ChorusCommand: Equatable {
    case install(codex: Bool, claude: Bool, repair: Bool)
    case uninstall(codex: Bool, claude: Bool)
    case daemon
    case menubar
    case hook(source: String)
    case speak(text: String, voice: String, speed: Double, volume: Double)
    case status
    case mute(String?)
    case mode(String?)
    case doctor
    case help

    public static let usageText = """
    chorus \(ChorusVersion.current)

    Usage:
      chorus install [--codex] [--claude] [--repair]
      chorus uninstall [--codex] [--claude]
      chorus daemon
      chorus menubar
      chorus hook --source <codex|claude>
      chorus speak --text <text> --voice <id> --speed <value> --volume <value>
      chorus status
      chorus mute [on|off|toggle]
      chorus mode [normal|focus|quiet|verbose|night]
      chorus doctor
    """

    public static func parse(_ arguments: [String]) throws -> ChorusCommand {
        // Finder double-click and bare `chorus` with no args launch the menu bar.
        // Use `chorus help` / `-h` for usage text.
        guard let name = arguments.first else { return .menubar }
        let tail = Array(arguments.dropFirst())

        switch name {
        case "--help", "-h", "help":
            guard tail.isEmpty else { throw CommandError.usage("help accepts no arguments") }
            return .help
        case "install":
            try requireOnly(tail, flags: ["--codex", "--claude", "--repair"])
            return .install(
                codex: tail.contains("--codex"),
                claude: tail.contains("--claude"),
                repair: tail.contains("--repair")
            )
        case "uninstall":
            try requireOnly(tail, flags: ["--codex", "--claude"])
            return .uninstall(codex: tail.contains("--codex"), claude: tail.contains("--claude"))
        case "daemon":
            try requireEmpty(tail, command: name)
            return .daemon
        case "menubar":
            try requireEmpty(tail, command: name)
            return .menubar
        case "hook":
            let source = try requiredValue("--source", in: tail)
            guard ["codex", "claude"].contains(source) else {
                throw CommandError.usage("--source must be codex or claude")
            }
            try requireFlagPairs(tail, flags: ["--source"])
            return .hook(source: source)
        case "speak":
            let text = try requiredValue("--text", in: tail)
            let voice = try requiredValue("--voice", in: tail)
            let speedRaw = try requiredValue("--speed", in: tail)
            let volumeRaw = try requiredValue("--volume", in: tail)
            guard let speed = Double(speedRaw), let volume = Double(volumeRaw) else {
                throw CommandError.usage("--speed and --volume must be numbers")
            }
            try requireFlagPairs(tail, flags: ["--text", "--voice", "--speed", "--volume"])
            return .speak(text: text, voice: voice, speed: speed, volume: volume)
        case "status":
            try requireEmpty(tail, command: name)
            return .status
        case "mute":
            guard tail.count <= 1, tail.first.map({ ["on", "off", "toggle"].contains($0) }) ?? true else {
                throw CommandError.usage("mute accepts on, off, or toggle")
            }
            return .mute(tail.first)
        case "mode":
            let modes = ["normal", "focus", "quiet", "verbose", "night"]
            guard tail.count <= 1, tail.first.map({ modes.contains($0) }) ?? true else {
                throw CommandError.usage("mode accepts normal, focus, quiet, verbose, or night")
            }
            return .mode(tail.first)
        case "doctor":
            try requireEmpty(tail, command: name)
            return .doctor
        default:
            throw CommandError.usage("unknown command: \(name)")
        }
    }

    private static func requireEmpty(_ arguments: [String], command: String) throws {
        guard arguments.isEmpty else { throw CommandError.usage("\(command) accepts no arguments") }
    }

    private static func requireOnly(_ arguments: [String], flags: Set<String>) throws {
        guard arguments.allSatisfy(flags.contains) else {
            throw CommandError.usage("unsupported option")
        }
    }

    private static func requiredValue(_ flag: String, in arguments: [String]) throws -> String {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            throw CommandError.usage("missing required \(flag)")
        }
        let value = arguments[index + 1]
        guard !value.hasPrefix("--") else { throw CommandError.usage("missing required \(flag)") }
        return value
    }

    private static func requireFlagPairs(_ arguments: [String], flags: Set<String>) throws {
        guard arguments.count.isMultiple(of: 2) else { throw CommandError.usage("invalid options") }
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard flags.contains(arguments[index]), !arguments[index + 1].hasPrefix("--") else {
                throw CommandError.usage("unsupported option")
            }
        }
    }
}
