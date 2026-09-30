import CryptoKit
import Darwin
import Foundation

public struct OwnedHook: Codable, Equatable, Sendable {
    public let host: HostSource
    public let event: HookEventName
    public let sha256: String
}

public struct OwnedInstalledFile: Codable, Equatable, Sendable {
    public let host: HostSource
    public let path: String
    public let sha256: String
}

public struct OwnedRuntimeFile: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
}

public struct InstallManifest: Codable, Equatable, Sendable {
    public var hooks: [OwnedHook]
    public var files: [OwnedInstalledFile]
    public var runtimeFiles: [OwnedRuntimeFile]

    public init(
        hooks: [OwnedHook] = [],
        files: [OwnedInstalledFile] = [],
        runtimeFiles: [OwnedRuntimeFile] = []
    ) {
        self.hooks = hooks
        self.files = files
        self.runtimeFiles = runtimeFiles
    }

    private enum CodingKeys: String, CodingKey { case hooks, files, runtimeFiles }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hooks = try container.decodeIfPresent([OwnedHook].self, forKey: .hooks) ?? []
        files = try container.decodeIfPresent([OwnedInstalledFile].self, forKey: .files) ?? []
        runtimeFiles = try container.decodeIfPresent([OwnedRuntimeFile].self, forKey: .runtimeFiles) ?? []
    }

    public static func load(from url: URL) throws -> InstallManifest {
        guard FileManager.default.fileExists(atPath: url.path) else { return InstallManifest() }
        return try JSONDecoder().decode(InstallManifest.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicInstallerFile.write(try encoder.encode(self), to: url, permissions: 0o600)
    }
}

enum InstallerDigest {
    static func data(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func json(_ value: Any) throws -> String {
        data(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
    }
}

enum AtomicInstallerFile {
    static func write(_ data: Data, to url: URL, permissions: Int) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: permissions]
        ) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? fileManager.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        if fileManager.fileExists(atPath: url.path) {
            guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, url.path, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try fileManager.removeItem(at: temporary)
        } else {
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
