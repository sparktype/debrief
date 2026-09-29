import Darwin
import Foundation

/// Round-robin companion voice for an agent session. The same id keeps its voice.
public struct SessionVoiceRotation: Equatable, Sendable, Codable {
    public static let order: [String] = [
        "F1", "F2", "F3", "F4", "F5",
        "M1", "M2", "M3", "M4", "M5",
    ]
    public static let retainedSessionLimit = 128

    public var next: Int
    public var sessions: [String: String]
    public var orderOfClaims: [String]

    public init(
        next: Int = 0,
        sessions: [String: String] = [:],
        orderOfClaims: [String] = []
    ) {
        self.next = next
        self.sessions = sessions
        self.orderOfClaims = orderOfClaims
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        next = try container.decodeIfPresent(Int.self, forKey: .next) ?? 0
        sessions = try container.decodeIfPresent([String: String].self, forKey: .sessions) ?? [:]
        orderOfClaims = try container.decodeIfPresent([String].self, forKey: .orderOfClaims)
            ?? Array(sessions.keys)
    }

    /// Returns the voice already stored for `sessionID`, or the next voice in `order`.
    public mutating func claim(_ sessionID: String) -> String {
        if let existing = sessions[sessionID] {
            return existing
        }
        let voice = Self.order[next % Self.order.count]
        next += 1
        sessions[sessionID] = voice
        orderOfClaims.append(sessionID)
        let overflow = orderOfClaims.count - Self.retainedSessionLimit
        if overflow > 0 {
            for identifier in orderOfClaims.prefix(overflow) {
                sessions.removeValue(forKey: identifier)
            }
            orderOfClaims.removeFirst(overflow)
        }
        return voice
    }
}

public enum SessionVoiceError: Error, Equatable, Sendable {
    case emptySession
    case lockFailed
}

/// Persists `SessionVoiceRotation` so hook and MCP processes share one cursor.
public struct SessionVoiceStore: Sendable {
    public let url: URL

    public init(home: URL) {
        self.url = ChorusPaths.forHome(home).sessionVoicesURL
    }

    public init(url: URL) {
        self.url = url
    }

    public func claim(_ sessionID: String) throws -> String {
        let identifier = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { throw SessionVoiceError.emptySession }

        let directory = url.deletingLastPathComponent()
        let directoryExisted = FileManager.default.fileExists(atPath: directory.path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !directoryExisted {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: Data("{}".utf8),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw SessionVoiceError.lockFailed
            }
        }

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0
        guard fcntl(handle.fileDescriptor, F_SETLKW, &lock) == 0 else {
            throw SessionVoiceError.lockFailed
        }
        defer {
            var unlock = flock()
            unlock.l_type = Int16(F_UNLCK)
            unlock.l_whence = Int16(SEEK_SET)
            unlock.l_start = 0
            unlock.l_len = 0
            _ = fcntl(handle.fileDescriptor, F_SETLK, &unlock)
        }

        let data = try handle.readToEnd() ?? Data()
        var state = (try? JSONDecoder().decode(SessionVoiceRotation.self, from: data))
            ?? SessionVoiceRotation()
        let voice = state.claim(identifier)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(state)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: encoded)
        try handle.truncate(atOffset: UInt64(encoded.count))
        return voice
    }
}
