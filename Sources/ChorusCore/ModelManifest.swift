import Foundation

public struct ModelAsset: Codable, Equatable, Sendable {
    public let relativePath: String
    public let url: URL
    public let byteCount: Int
    public let sha256: String

    public init(relativePath: String, url: URL, byteCount: Int, sha256: String) {
        self.relativePath = relativePath
        self.url = url
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public enum ModelManifestError: Error, Equatable, Sendable {
    case invalidName
    case invalidRevision
    case emptyAssets
    case invalidRelativePath
    case duplicateRelativePath
    case invalidURL
    case mutableURL
    case invalidByteCount
    case invalidSHA256
}

public struct ModelManifest: Codable, Equatable, Sendable {
    public let name: String
    public let revision: String
    public let assets: [ModelAsset]

    public init(name: String, revision: String, assets: [ModelAsset]) {
        self.name = name
        self.revision = revision
        self.assets = assets
    }

    public func validate() throws {
        guard !name.isEmpty else { throw ModelManifestError.invalidName }
        guard revision.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              revision != ".", revision != ".." else {
            throw ModelManifestError.invalidRevision
        }
        guard !assets.isEmpty else { throw ModelManifestError.emptyAssets }

        var paths = Set<String>()
        for asset in assets {
            let components = asset.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !asset.relativePath.hasPrefix("/"),
                  !asset.relativePath.contains("\\"),
                  !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw ModelManifestError.invalidRelativePath
            }
            guard paths.insert(asset.relativePath).inserted else {
                throw ModelManifestError.duplicateRelativePath
            }
            guard asset.url.scheme == "https", asset.url.host != nil else {
                throw ModelManifestError.invalidURL
            }
            guard asset.url.absoluteString.contains("/resolve/\(revision)/") else {
                throw ModelManifestError.mutableURL
            }
            guard asset.byteCount > 0 else { throw ModelManifestError.invalidByteCount }
            guard asset.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw ModelManifestError.invalidSHA256
            }
        }
    }
}

public extension ModelManifest {
    static let supertonic3: ModelManifest = {
        let revision = "3cadd1ee6394adea1bd021217a0e650ede09a323"
        let base = "https://huggingface.co/Supertone/supertonic-3/resolve/\(revision)/"
        func asset(_ path: String, _ size: Int, _ digest: String) -> ModelAsset {
            ModelAsset(
                relativePath: path,
                url: URL(string: base + path)!,
                byteCount: size,
                sha256: digest
            )
        }
        return ModelManifest(name: "supertonic-3", revision: revision, assets: [
            asset("onnx/duration_predictor.onnx", 3_700_147, "c3eb91414d5ff8a7a239b7fe9e34e7e2bf8a8140d8375ffb14718b1c639325db"),
            asset("onnx/text_encoder.onnx", 36_416_150, "c7befd5ea8c3119769e8a6c1486c4edc6a3bc8365c67621c881bbb774b9902ff"),
            asset("onnx/vector_estimator.onnx", 256_534_781, "883ac868ea0275ef0e991524dc64f16b3c0376efd7c320af6b53f5b780d7c61c"),
            asset("onnx/vocoder.onnx", 101_424_195, "085de76dd8e8d5836d6ca66826601f615939218f90e519f70ee8a36ed2a4c4ba"),
            asset("onnx/tts.json", 8_253, "42078d3aef1cd43ab43021f3c54f47d2d75ceb4e75f627f118890128b06a0d09"),
            asset("onnx/unicode_indexer.json", 277_676, "9bf7346e43883a81f8645c81224f786d43c5b57f3641f6e7671a7d6c493cb24f"),
            asset("voice_styles/F1.json", 292_046, "bbdec6ee00231c2c742ad05483df5334cab3b52fda3ba38e6a07059c4563dbc2"),
            asset("voice_styles/F2.json", 292_423, "7c722c6a72707b1a77f035d67f0d1351ba187738e06f7683e8c72b1df3477fc6"),
            asset("voice_styles/F3.json", 290_794, "12f6ef2573baa2defa1128069cb59f203e3ab67c92af77b42df8a0e3a2f7c6ab"),
            asset("voice_styles/F4.json", 291_808, "c2fa764c1225a76dfc3e2c73e8aa4f70d9ee48793860eb34c295fff01c2e032b"),
            asset("voice_styles/F5.json", 291_479, "45966e73316415626cf41a7d1c6f3b4c70dbc1ba2bee5c1978ef0ce33244fc8d"),
            asset("voice_styles/M1.json", 291_748, "e35604687f5d23694b8e91593a93eec0e4eca6c0b02bb8ed69139ab2ea6b0a5b"),
            asset("voice_styles/M2.json", 292_055, "b76cbf62bac707c710cf0ae5aba5e31eea1a6339a9734bfae33ab98499534a50"),
            asset("voice_styles/M3.json", 290_198, "ea1ac35ccb91b0d7ecad533a2fbd0eec10c91513d8951e3b25fbba99954e159b"),
            asset("voice_styles/M4.json", 291_522, "ca8eefad4fcd989c9379032ff3e50738adc547eeb5e221b82593a6d7b3bac303"),
            asset("voice_styles/M5.json", 291_469, "dd22b92740314321f8ae11c5e87f8dd60d060f15dd3a632b5adf77f471f77af2"),
        ])
    }()
}
