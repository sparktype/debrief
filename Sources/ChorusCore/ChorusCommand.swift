// 설치·데몬·제어 명령 파싱
import Foundation

public enum CommandError: Error, Equatable, CustomStringConvertible {
    case usage(String)

    public var description: String {
        switch self {
        case let .usage(message): message
        }
    }
}

/// Process entry modes. Agents use `hook` / `mcp`; a person uses the CLI.
public enum ChorusCommand: Equatable, Sendable {
    case install(codex: Bool, claude: Bool, grok: Bool, repair: Bool)
    case uninstall(codex: Bool, claude: Bool, grok: Bool)
    case daemon
    case start
    case stop
    case status
    case mute(String?)
    case mode(String?)
    case companion(String?)
    case doctor
    case hook(source: String)
    case mcp
    case help

    public static let usageText = """
    debrief \(ChorusVersion.current)

    Install / repair (release build, then):
      debrief install [--codex] [--claude] [--grok] [--repair]
      debrief uninstall [--codex] [--claude] [--grok]

    Service:
      debrief daemon
      debrief start
      debrief stop
      debrief status
      debrief doctor

    Controls (written to config.json; applied on the next utterance):
      debrief mute [on|off|toggle]
      debrief mode [normal|focus|quiet|verbose|night]
      debrief companion [on|off|toggle]

    Agents:
      debrief mcp
      debrief hook --source <codex|claude>
      debrief help
    """

    public static func parse(_ arguments: [String]) throws -> ChorusCommand {
        guard let name = arguments.first else { return .help }
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
        case "daemon":
            try requireEmpty(tail, command: name)
            return .daemon
        case "start":
            try requireEmpty(tail, command: name)
            return .start
        case "stop":
            try requireEmpty(tail, command: name)
            return .stop
        case "status":
            try requireEmpty(tail, command: name)
            return .status
        case "doctor":
            try requireEmpty(tail, command: name)
            return .doctor
        case "mute":
            return .mute(try optionalChoice(tail, allowed: ["on", "off", "toggle"], command: name))
        case "mode":
            return .mode(
                try optionalChoice(
                    tail,
                    allowed: Set(ChorusMode.allCases.map(\.rawValue)),
                    command: name
                )
            )
        case "companion":
            return .companion(try optionalChoice(tail, allowed: ["on", "off", "toggle"], command: name))
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
        default:
            throw CommandError.usage("unknown command: \(name)")
        }
    }

    private static func optionalChoice(
        _ arguments: [String],
        allowed: Set<String>,
        command: String
    ) throws -> String? {
        if arguments.isEmpty { return nil }
        guard arguments.count == 1, let value = arguments.first, allowed.contains(value) else {
            throw CommandError.usage("unsupported \(command) argument")
        }
        return value
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

/// Korean sentences the CLI prints. Help text stays English.
public enum CliMessages {
    public static let muted = "음소거했습니다."
    public static let unmuted = "음소거를 해제했습니다."
    public static let companionOn = "도우미 음성을 켰습니다."
    public static let companionOff = "도우미 음성을 껐습니다."
    public static let started = "서비스를 시작했습니다."
    public static let stopped = "서비스를 중지했습니다."
    public static let alreadyRunning = "이미 실행 중입니다."
    public static let launchAgentMissing = "LaunchAgent가 없습니다. debrief install을 실행하세요."
    public static let executablePathIsDirectory =
        "실행 파일 경로가 디렉터리입니다. ~/.local/bin/debrief 를 비운 뒤 다시 설치하세요."

    public static func currentMode(_ mode: String) -> String {
        "현재 모드는 \(mode)입니다."
    }

    public static func modeSet(_ mode: String) -> String {
        "모드를 \(mode)로 설정했습니다."
    }

    public static func startFailed(_ reason: String) -> String {
        "서비스를 시작하지 못했습니다. \(reason)"
    }

    public static func stopFailed(_ reason: String) -> String {
        "서비스를 중지하지 못했습니다. \(reason)"
    }

    public static func configSaveFailed(_ reason: String) -> String {
        "설정을 저장하지 못했습니다. \(reason)"
    }
}
