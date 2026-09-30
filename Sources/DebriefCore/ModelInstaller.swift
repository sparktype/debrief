import CryptoKit
import Darwin
import Foundation

public protocol ModelDownloading: Sendable {
    func download(_ asset: ModelAsset, to destination: URL) async throws
}

public struct URLSessionModelDownloader: ModelDownloading {
    public init() {}

    public func download(_ asset: ModelAsset, to destination: URL) async throws {
        let (temporaryURL, response) = try await URLSession.shared.download(from: asset.url)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw ModelInstallerError.downloadFailed
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let file = try FileHandle(forWritingTo: destination)
        try file.synchronize()
        try file.close()
    }
}

public enum ModelInstallerError: Error, Equatable, Sendable {
    case downloadFailed
    case byteCountMismatch
    case checksumMismatch
    case invalidCurrentPointer
    case atomicReplacementFailed
}

public struct InstalledModel: Equatable, Sendable {
    public let revision: String
    public let directory: URL

    public init(revision: String, directory: URL) {
        self.revision = revision
        self.directory = directory
    }

    public static func resolveCurrent(in modelsDirectory: URL, name: String = "supertonic-3") throws -> InstalledModel {
        let root = modelsDirectory.appending(path: name, directoryHint: .isDirectory)
        let pointer = root.appending(path: "current.json")
        let value = try JSONDecoder().decode(CurrentModelPointer.self, from: Data(contentsOf: pointer))
        guard value.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              value.relativePath == value.revision else {
            throw ModelInstallerError.invalidCurrentPointer
        }
        let directory = root.appending(path: value.relativePath, directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ModelInstallerError.invalidCurrentPointer
        }
        return InstalledModel(revision: value.revision, directory: directory)
    }
}

private struct CurrentModelPointer: Codable, Equatable, Sendable {
    let revision: String
    let relativePath: String
}

public struct ModelInstaller<Downloader: ModelDownloading>: Sendable {
    private static var installationName: String { "supertonic-3" }
    private let modelsDirectory: URL
    private let manifest: ModelManifest
    private let downloader: Downloader

    public init(modelsDirectory: URL, manifest: ModelManifest, downloader: Downloader) {
        self.modelsDirectory = modelsDirectory
        self.manifest = manifest
        self.downloader = downloader
    }

    public func install(repair: Bool) async throws -> InstalledModel {
        let fileManager = FileManager.default
        try manifest.validate()
        let root = modelsDirectory.appending(path: Self.installationName, directoryHint: .isDirectory)
        let final = root.appending(path: manifest.revision, directoryHint: .isDirectory)
        let staging = root.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var stagingNeedsRemoval = true
        defer {
            if stagingNeedsRemoval { try? fileManager.removeItem(at: staging) }
        }

        for asset in manifest.assets {
            let destination = staging.appending(path: asset.relativePath)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let existing = final.appending(path: asset.relativePath)
            if repair, Self.isValid(asset: asset, at: existing) {
                try fileManager.copyItem(at: existing, to: destination)
            } else {
                try await downloader.download(asset, to: destination)
            }
            try Self.validate(asset: asset, at: destination)
        }

        try writeValidatedMarker(to: staging)
        try syncDirectory(staging)
        if fileManager.fileExists(atPath: final.path) {
            guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, final.path, UInt32(RENAME_SWAP)) == 0 else {
                throw ModelInstallerError.atomicReplacementFailed
            }
            try fileManager.removeItem(at: staging)
        } else {
            guard rename(staging.path, final.path) == 0 else {
                throw ModelInstallerError.atomicReplacementFailed
            }
        }
        stagingNeedsRemoval = false
        try syncDirectory(root)
        try writeCurrentPointer(in: root)
        return InstalledModel(revision: manifest.revision, directory: final)
    }

    private static func validate(asset: ModelAsset, at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue == asset.byteCount else {
            throw ModelInstallerError.checksumMismatch
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while true {
            let data = try file.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == asset.sha256 else { throw ModelInstallerError.checksumMismatch }
    }

    private static func isValid(asset: ModelAsset, at url: URL) -> Bool {
        do {
            try validate(asset: asset, at: url)
            return true
        } catch {
            return false
        }
    }

    private func writeValidatedMarker(to directory: URL) throws {
        let marker = directory.appending(path: ".validated.json")
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: marker, options: .atomic)
        let file = try FileHandle(forWritingTo: marker)
        try file.synchronize()
        try file.close()
    }

    private func writeCurrentPointer(in root: URL) throws {
        let fileManager = FileManager.default
        let pointer = CurrentModelPointer(revision: manifest.revision, relativePath: manifest.revision)
        let data = try JSONEncoder().encode(pointer)
        let temporary = root.appending(path: ".current-\(UUID().uuidString).json")
        try data.write(to: temporary)
        let file = try FileHandle(forWritingTo: temporary)
        try file.synchronize()
        try file.close()
        let current = root.appending(path: "current.json")
        if fileManager.fileExists(atPath: current.path) {
            guard renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, current.path, UInt32(RENAME_SWAP)) == 0 else {
                try? fileManager.removeItem(at: temporary)
                throw ModelInstallerError.atomicReplacementFailed
            }
            try fileManager.removeItem(at: temporary)
        } else {
            guard rename(temporary.path, current.path) == 0 else {
                try? fileManager.removeItem(at: temporary)
                throw ModelInstallerError.atomicReplacementFailed
            }
        }
        try syncDirectory(root)
    }

    private func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
