import Foundation
import Testing
@testable import DebriefCore

@Suite("ModelManifestTests")
struct ModelManifestTests {
    @Test func supertonicManifestIsImmutableCompleteAndUnique() throws {
        let manifest = ModelManifest.supertonic3
        let paths = manifest.assets.map(\.relativePath)
        let voices = paths.filter { $0.hasPrefix("voice_styles/") }

        #expect(manifest.revision == "3cadd1ee6394adea1bd021217a0e650ede09a323")
        #expect(Set(paths).count == paths.count)
        #expect(paths.count == 16)
        #expect(Set(voices) == Set(
            VoiceCatalog.allowedVoiceIDs.map { "voice_styles/\($0).json" }
        ))
        #expect(manifest.assets.allSatisfy { asset in
            asset.byteCount > 0
                && asset.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
                && asset.url.scheme == "https"
                && asset.url.absoluteString.contains("/resolve/\(manifest.revision)/")
        })
        try manifest.validate()
    }

    @Test func validationRejectsTraversalAndDuplicatePaths() {
        let asset = ModelAsset(
            relativePath: "../escape",
            url: URL(string: "https://example.invalid/resolve/abc/escape")!,
            byteCount: 1,
            sha256: String(repeating: "a", count: 64)
        )
        let duplicate = ModelAsset(
            relativePath: "safe",
            url: URL(string: "https://example.invalid/resolve/abc/safe")!,
            byteCount: 1,
            sha256: String(repeating: "b", count: 64)
        )

        #expect(throws: ModelManifestError.invalidRelativePath) {
            try ModelManifest(name: "x", revision: "abc", assets: [asset]).validate()
        }
        #expect(throws: ModelManifestError.duplicateRelativePath) {
            try ModelManifest(name: "x", revision: "abc", assets: [duplicate, duplicate]).validate()
        }
    }
}
