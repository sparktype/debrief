import Darwin
import Foundation

public enum ChorusMode: String, Codable, CaseIterable, Sendable {
    case normal
    case focus
    case quiet
    case verbose
    case night
}

public struct ChorusConfiguration: Codable, Equatable, Sendable {
    public static let defaultVolumeCeilings: [String: Double] = [
        ChorusMode.normal.rawValue: 1.0,
        ChorusMode.focus.rawValue: 1.0,
        ChorusMode.quiet.rawValue: 0.45,
        ChorusMode.verbose.rawValue: 1.0,
        ChorusMode.night.rawValue: 0.20,
    ]
    public static let `default` = ChorusConfiguration(mode: .normal, muted: false)

    public var mode: ChorusMode
    public var muted: Bool
    public var volumeCeilings: [String: Double]

    public init(
        mode: ChorusMode,
        muted: Bool,
        volumeCeilings: [String: Double] = defaultVolumeCeilings
    ) {
        self.mode = mode
        self.muted = muted
        self.volumeCeilings = volumeCeilings
    }

    public static func load(from url: URL) -> ChorusConfiguration {
        guard let data = try? Data(contentsOf: url),
              let configuration = try? JSONDecoder().decode(ChorusConfiguration.self, from: data)
        else {
            return .default
        }
        return configuration
    }

    public func save(to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let data = try JSONEncoder.chorus.encode(self)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? fileManager.removeItem(at: temporary) }

        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

public enum ConfigurationCommandError: Error, Equatable, Sendable {
    case invalidMode(String)
    case invalidMuteAction(String)
}

public enum ConfigurationCommands {
    public static func applyMode(_ rawValue: String?, home: URL) throws -> ChorusConfiguration {
        let url = ChorusPaths.forHome(home).configURL
        var configuration = ChorusConfiguration.load(from: url)
        guard let rawValue else { return configuration }
        guard let mode = ChorusMode(rawValue: rawValue) else {
            throw ConfigurationCommandError.invalidMode(rawValue)
        }
        configuration.mode = mode
        try configuration.save(to: url)
        return configuration
    }

    public static func applyMute(_ rawValue: String?, home: URL) throws -> ChorusConfiguration {
        let url = ChorusPaths.forHome(home).configURL
        var configuration = ChorusConfiguration.load(from: url)
        switch rawValue ?? "toggle" {
        case "on": configuration.muted = true
        case "off": configuration.muted = false
        case "toggle": configuration.muted.toggle()
        case let invalid: throw ConfigurationCommandError.invalidMuteAction(invalid)
        }
        try configuration.save(to: url)
        return configuration
    }
}

private extension JSONEncoder {
    static var chorus: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
