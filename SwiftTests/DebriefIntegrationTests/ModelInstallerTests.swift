import CryptoKit
import Foundation
import Testing
@testable import DebriefCore

@Suite("ModelInstallerTests")
struct ModelInstallerTests {
    @Test func repairDownloadsOnlyMissingOrInvalidFiles() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Data("already valid".utf8)
        let second = Data("download me".utf8)
        let manifest = try fixtureManifest(revision: String(repeating: "a", count: 40), [
            ("onnx/a.bin", first), ("voice_styles/F1.json", second),
        ])
        let revision = root.appending(path: "supertonic-3/\(manifest.revision)")
        let existing = revision.appending(path: "onnx/a.bin")
        try FileManager.default.createDirectory(
            at: existing.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try first.write(to: existing)
        let downloader = FakeModelDownloader(contents: Dictionary(
            uniqueKeysWithValues: manifest.assets.map { ($0.url, $0.relativePath.hasSuffix("a.bin") ? first : second) }
        ))

        let installed = try await ModelInstaller(
            modelsDirectory: root,
            manifest: manifest,
            downloader: downloader
        ).install(repair: true)

        #expect(await downloader.requestedPaths == ["voice_styles/F1.json"])
        #expect(try Data(contentsOf: installed.directory.appending(path: "onnx/a.bin")) == first)
        #expect(try Data(contentsOf: installed.directory.appending(path: "voice_styles/F1.json")) == second)
        #expect(try InstalledModel.resolveCurrent(in: root) == installed)
    }

    @Test func checksumFailurePreservesPreviouslyActiveRevision() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldData = Data("old-good".utf8)
        let oldManifest = try fixtureManifest(
            revision: String(repeating: "1", count: 40),
            [("onnx/model.bin", oldData)]
        )
        let oldDownloader = FakeModelDownloader(contents: [oldManifest.assets[0].url: oldData])
        let oldInstalled = try await ModelInstaller(
            modelsDirectory: root,
            manifest: oldManifest,
            downloader: oldDownloader
        ).install(repair: false)
        let pointer = root.appending(path: "supertonic-3/current.json")
        let pointerBefore = try Data(contentsOf: pointer)

        let expected = Data("new-good".utf8)
        let newManifest = try fixtureManifest(
            revision: String(repeating: "2", count: 40),
            [("onnx/model.bin", expected)]
        )
        let corruptDownloader = FakeModelDownloader(
            contents: [newManifest.assets[0].url: Data("corrupt".utf8)]
        )

        await #expect(throws: ModelInstallerError.checksumMismatch) {
            try await ModelInstaller(
                modelsDirectory: root,
                manifest: newManifest,
                downloader: corruptDownloader
            ).install(repair: false)
        }
        #expect(try Data(contentsOf: pointer) == pointerBefore)
        #expect(FileManager.default.fileExists(atPath: oldInstalled.directory.path))
        #expect(!FileManager.default.fileExists(
            atPath: root.appending(path: "supertonic-3/\(newManifest.revision)").path
        ))
    }

    private func fixtureManifest(
        revision: String,
        _ files: [(String, Data)]
    ) throws -> ModelManifest {
        let assets = files.map { path, data in
            ModelAsset(
                relativePath: path,
                url: URL(string: "https://example.invalid/resolve/\(revision)/\(path)")!,
                byteCount: data.count,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            )
        }
        let manifest = ModelManifest(name: "fixture", revision: revision, assets: assets)
        try manifest.validate()
        return manifest
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "debrief-model-tests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor FakeModelDownloader: ModelDownloading {
    private let contents: [URL: Data]
    private(set) var requestedPaths: [String] = []

    init(contents: [URL: Data]) { self.contents = contents }

    func download(_ asset: ModelAsset, to destination: URL) async throws {
        requestedPaths.append(asset.relativePath)
        guard let data = contents[asset.url] else { throw CocoaError(.fileNoSuchFile) }
        try data.write(to: destination)
    }
}
