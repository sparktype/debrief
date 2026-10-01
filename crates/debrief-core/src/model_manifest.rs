// 모델 매니페스트 정의 및 내장 supertonic-3 자산 목록
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelAsset {
    pub relative_path: String,
    pub url: String,
    pub byte_count: u64,
    pub sha256: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModelManifest {
    pub name: String,
    pub revision: String,
    pub assets: Vec<ModelAsset>,
}

#[derive(Debug, PartialEq)]
pub enum ModelManifestError {
    InvalidName,
    InvalidRevision,
    EmptyAssets,
    InvalidRelativePath,
    DuplicateRelativePath,
    InvalidUrl,
    MutableUrl,
    InvalidByteCount,
    InvalidSha256,
}

impl ModelManifest {
    pub fn validate(&self) -> Result<(), ModelManifestError> {
        if self.name.is_empty() {
            return Err(ModelManifestError::InvalidName);
        }
        let revision_ok = !self.revision.is_empty()
            && self.revision.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
            && self.revision != "."
            && self.revision != ".."
            && !self.revision.contains('/');
        if !revision_ok {
            return Err(ModelManifestError::InvalidRevision);
        }
        if self.assets.is_empty() {
            return Err(ModelManifestError::EmptyAssets);
        }

        let mut seen_paths = std::collections::HashSet::new();
        for asset in &self.assets {
            let components: Vec<&str> = asset.relative_path.split('/').collect();
            let path_ok = !asset.relative_path.starts_with('/')
                && !asset.relative_path.contains('\\')
                && !components.is_empty()
                && components.iter().all(|c| !c.is_empty() && *c != "." && *c != "..");
            if !path_ok {
                return Err(ModelManifestError::InvalidRelativePath);
            }
            if !seen_paths.insert(asset.relative_path.clone()) {
                return Err(ModelManifestError::DuplicateRelativePath);
            }

            let is_https = asset.url.starts_with("https://");
            let has_host = asset.url.strip_prefix("https://").map(|rest| !rest.is_empty() && !rest.starts_with('/')).unwrap_or(false);
            if !is_https || !has_host {
                return Err(ModelManifestError::InvalidUrl);
            }
            if !asset.url.contains(&format!("/resolve/{}/", self.revision)) {
                return Err(ModelManifestError::MutableUrl);
            }
            if asset.byte_count == 0 {
                return Err(ModelManifestError::InvalidByteCount);
            }
            let sha_ok = asset.sha256.len() == 64 && asset.sha256.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase());
            if !sha_ok {
                return Err(ModelManifestError::InvalidSha256);
            }
        }
        Ok(())
    }

    pub fn supertonic3() -> ModelManifest {
        let revision = "3cadd1ee6394adea1bd021217a0e650ede09a323".to_string();
        let base = format!("https://huggingface.co/Supertone/supertonic-3/resolve/{revision}/");
        let asset = |path: &str, byte_count: u64, sha256: &str| ModelAsset {
            relative_path: path.to_string(),
            url: format!("{base}{path}"),
            byte_count,
            sha256: sha256.to_string(),
        };
        ModelManifest {
            name: "supertonic-3".to_string(),
            revision,
            assets: vec![
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
            ],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_asset(path: &str) -> ModelAsset {
        ModelAsset {
            relative_path: path.to_string(),
            url: format!("https://huggingface.co/Supertone/supertonic-3/resolve/abcdef0123456789abcdef0123456789abcdef01/{path}"),
            byte_count: 100,
            sha256: "a".repeat(64),
        }
    }

    fn valid_manifest() -> ModelManifest {
        ModelManifest {
            name: "supertonic-3".to_string(),
            revision: "abcdef0123456789abcdef0123456789abcdef01".to_string(),
            assets: vec![valid_asset("onnx/tts.json")],
        }
    }

    #[test]
    fn valid_manifest_passes() {
        assert!(valid_manifest().validate().is_ok());
    }

    #[test]
    fn empty_name_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.name = String::new();
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidName));
    }

    #[test]
    fn revision_with_path_traversal_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.revision = "..".to_string();
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidRevision));
    }

    #[test]
    fn revision_with_slash_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.revision = "abc/def".to_string();
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidRevision));
    }

    #[test]
    fn empty_assets_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets = vec![];
        assert_eq!(manifest.validate(), Err(ModelManifestError::EmptyAssets));
    }

    #[test]
    fn absolute_relative_path_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets[0].relative_path = "/etc/passwd".to_string();
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidRelativePath));
    }

    #[test]
    fn relative_path_with_dot_dot_component_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets[0].relative_path = "onnx/../../../etc/passwd".to_string();
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidRelativePath));
    }

    #[test]
    fn relative_path_with_backslash_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets[0].relative_path = "onnx\\evil.onnx".to_string();
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidRelativePath));
    }

    #[test]
    fn duplicate_relative_paths_are_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets.push(valid_asset("onnx/tts.json"));
        assert_eq!(manifest.validate(), Err(ModelManifestError::DuplicateRelativePath));
    }

    #[test]
    fn non_https_url_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets[0].url = "http://huggingface.co/Supertone/supertonic-3/resolve/abcdef0123456789abcdef0123456789abcdef01/onnx/tts.json".to_string();
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidUrl));
    }

    #[test]
    fn url_not_pinned_to_revision_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets[0].url = "https://huggingface.co/Supertone/supertonic-3/resolve/main/onnx/tts.json".to_string();
        assert_eq!(manifest.validate(), Err(ModelManifestError::MutableUrl));
    }

    #[test]
    fn zero_byte_count_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets[0].byte_count = 0;
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidByteCount));
    }

    #[test]
    fn malformed_sha256_is_rejected() {
        let mut manifest = valid_manifest();
        manifest.assets[0].sha256 = "not-a-hash".to_string();
        assert_eq!(manifest.validate(), Err(ModelManifestError::InvalidSha256));
    }

    #[test]
    fn embedded_supertonic3_manifest_validates() {
        ModelManifest::supertonic3().validate().expect("embedded manifest must be valid");
    }

    #[test]
    fn embedded_supertonic3_manifest_matches_known_revision_and_asset_count() {
        let manifest = ModelManifest::supertonic3();
        assert_eq!(manifest.name, "supertonic-3");
        assert_eq!(manifest.revision, "3cadd1ee6394adea1bd021217a0e650ede09a323");
        assert_eq!(manifest.assets.len(), 16);
    }
}
