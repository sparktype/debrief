// 앱·훅·설치 진입 파싱 (사용자 CLI 표면 없음)
import Foundation

public enum CommandError: Error, Equatable, CustomStringConvertible {
    case usage(String)

    public var description: String {
        switch self {
        case let .usage(message): message
        }
    }
}

/// Process entry modes. User-facing control is the menu bar; agents use `hook` / `mcp`.
public enum ChorusCommand: Equatable, Sendable {
    case install(codex: Bool, claude: Bool, grok: Bool, repair: Bool)
    case uninstall(codex: Bool, claude: Bool, grok: Bool)
    case menubar
    case hook(source: String)
    case mcp
    case help

    public static let usageText = """
    Chorus \(ChorusVersion.current)

    Install / repair (from a build tree):
      chorus install [--codex] [--claude] [--grok] [--repair]
      chorus uninstall [--codex] [--claude] [--grok]

    Runtime (Chorus.app / LaunchAgent):
      (no args) | menubar     menu bar resident
      mcp                 MCP stdio server (speak tool)
      hook --source <codex|claude>

    Mute, mode, start/stop, and quit are controlled from the menu bar only.
    """

    public static func parse(_ arguments: [String]) throws -> ChorusCommand {
        // Finder double-click and bare launch open the menu bar.
        guard let name = arguments.first else { return .menubar }
        let tail = Array(arguments.dropFirst())

        switch name {
        case "--help", "-h", "help":
            guard tail.isEmpty else { throw CommandError.usage("help accepts no arguments") }
            return .help
        case "install":
            try requireOnly(tail, flags: ["--codex", "--claude", "--grok", "--repair"])
            return .install(
                codex: tail.contains("--codex"),
                claude: tail.contains("--claude"),
                grok: tail.contains("--grok"),
                repair: tail.contains("--repair")
            )
        case "uninstall":
            try requireOnly(tail, flags: ["--codex", "--claude", "--grok"])
            return .uninstall(
                codex: tail.contains("--codex"),
                claude: tail.contains("--claude"),
                grok: tail.contains("--grok")
            )
        case "menubar":
            try requireEmpty(tail, command: name)
            return .menubar
        case "mcp":
            try requireEmpty(tail, command: name)
            return .mcp
        case "hook":
            let source = try requiredValue("--source", in: tail)
            guard ["codex", "claude"].contains(source) else {
                throw CommandError.usage("--source must be codex or claude")
            }
            try requireFlagPairs(tail, flags: ["--source"])
            return .hook(source: source)
        case "daemon", "speak", "status", "mute", "mode", "doctor":
            throw CommandError.usage(
                "removed CLI command '\(name)'; use the Chorus menu bar for mute/mode/status"
            )
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
