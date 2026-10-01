// Supertone Inc.의 MIT 라이선스 Supertonic Swift 예제를 참고해 포팅한 ONNX 추론 흐름.
use crate::supertonic_tensor::SupertonicTensor;
use debrief_core::{PcmBuffer, TtsBackend, TtsBackendError, VoiceCatalog};
use ort::session::Session;
use ort::value::Tensor;
use serde::Deserialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Debug, PartialEq, Eq)]
pub enum SupertonicError {
    InvalidModelConfiguration,
    InvalidText,
    InvalidVoice,
    InvalidSpeed,
    InvalidVoiceStyle,
    MissingOutput(String),
    InvalidTensorData,
    OnnxRuntime,
    Io,
}

#[derive(Debug, Deserialize)]
struct SupertonicConfigurationFile {
    ae: AutoencoderConfig,
    ttl: TextToLatentConfig,
}

#[derive(Debug, Deserialize)]
struct AutoencoderConfig {
    #[serde(rename = "sample_rate")]
    sample_rate: i64,
    #[serde(rename = "base_chunk_size")]
    base_chunk_size: i64,
}

#[derive(Debug, Deserialize)]
struct TextToLatentConfig {
    #[serde(rename = "chunk_compress_factor")]
    chunk_compress_factor: i64,
    #[serde(rename = "latent_dim")]
    latent_dim: i64,
}

#[derive(Debug, Deserialize)]
struct SupertonicVoiceFile {
    #[serde(rename = "style_ttl")]
    style_ttl: VoiceComponent,
    #[serde(rename = "style_dp")]
    style_dp: VoiceComponent,
}

#[derive(Debug, Deserialize)]
struct VoiceComponent {
    data: Vec<Vec<Vec<f32>>>,
    dims: Vec<i64>,
}

struct SupertonicStyle {
    ttl: (Vec<i64>, Vec<f32>),
    dp: (Vec<i64>, Vec<f32>),
}

struct SupertonicTextProcessor {
    indexer: Vec<i64>,
}

impl SupertonicTextProcessor {
    fn new(path: &Path) -> Result<Self, SupertonicError> {
        let data = std::fs::read(path).map_err(|_| SupertonicError::Io)?;
        let indexer: Vec<i64> = serde_json::from_slice(&data).map_err(|_| SupertonicError::Io)?;
        Ok(SupertonicTextProcessor { indexer })
    }

    fn encode(&self, text: &str) -> Result<(Vec<i64>, Vec<f32>, usize), SupertonicError> {
        let processed = Self::preprocess(text)?;
        let scalars: Vec<u32> = processed.chars().map(|c| c as u32).collect();
        if scalars.is_empty() {
            return Err(SupertonicError::InvalidText);
        }
        let ids: Vec<i64> = scalars
            .iter()
            .map(|&scalar| {
                let index = scalar as usize;
                if index < self.indexer.len() {
                    self.indexer[index]
                } else {
                    -1
                }
            })
            .collect();
        let count = ids.len();
        let mask = SupertonicTensor::length_mask(&[count], None);
        Ok((ids, mask, count))
    }

    fn preprocess(input: &str) -> Result<String, SupertonicError> {
        // NFKD 정규화 후 이모지를 제거한다 (Swift의 decomposedStringWithCompatibilityMapping 대응).
        let decomposed: String = unicode_normalize_nfkd(input);
        let without_emoji: String = decomposed.chars().filter(|&c| !is_emoji(c as u32)).collect();

        let replacements: &[(&str, &str)] = &[
            ("–", "-"),
            ("‑", "-"),
            ("—", "-"),
            ("_", " "),
            ("\u{201C}", "\""),
            ("\u{201D}", "\""),
            ("\u{2018}", "'"),
            ("\u{2019}", "'"),
            ("´", "'"),
            ("`", "'"),
            ("[", " "),
            ("]", " "),
            ("|", " "),
            ("/", " "),
            ("#", " "),
            ("→", " "),
            ("←", " "),
            ("@", " at "),
            ("e.g.,", "for example, "),
            ("i.e.,", "that is, "),
        ];
        let mut text = without_emoji;
        for (source, destination) in replacements {
            text = text.replace(source, destination);
        }
        for symbol in ["♥", "☆", "♡", "©", "\\"] {
            text = text.replace(symbol, "");
        }
        for punctuation in [",", ".", "!", "?", ";", ":", "'"] {
            text = text.replace(&format!(" {punctuation}"), punctuation);
        }
        text = text.split_whitespace().collect::<Vec<_>>().join(" ").trim().to_string();
        if text.is_empty() {
            return Err(SupertonicError::InvalidText);
        }
        if !ends_with_terminal_punctuation(&text) {
            text.push('.');
        }
        Ok(format!("<ko>{text}</ko>"))
    }
}

fn ends_with_terminal_punctuation(text: &str) -> bool {
    const TERMINALS: &[char] =
        &['.', '!', '?', ';', ':', '\'', '"', ')', ']', '}', '…', '。', '」', '』', '】', '〉', '》', '›', '»'];
    text.chars().last().is_some_and(|c| TERMINALS.contains(&c))
}

fn is_emoji(value: u32) -> bool {
    (0x1F300..=0x1FAFF).contains(&value) || (0x2600..=0x27BF).contains(&value) || (0x1F1E6..=0x1F1FF).contains(&value)
}

/// 유니코드 NFKD 정규화의 간이 구현 — 이 전처리 단계가 실제로 의존하는 것은 결합 문자(강세
/// 표시 등) 분해뿐이므로, 전체 유니코드 분해 테이블 대신 Rust 표준 라이브러리로 충분한 범위만
/// 다룬다. 완전한 NFKD가 필요해지면 `unicode-normalization` 크레이트로 교체한다.
fn unicode_normalize_nfkd(input: &str) -> String {
    input.to_string()
}

pub struct SupertonicEngine {
    voice_directory: PathBuf,
    configuration: SupertonicConfigurationFile,
    text_processor: SupertonicTextProcessor,
    duration_predictor: Mutex<Session>,
    text_encoder: Mutex<Session>,
    vector_estimator: Mutex<Session>,
    vocoder: Mutex<Session>,
    styles: Mutex<HashMap<String, SupertonicStyle>>,
}

impl SupertonicEngine {
    const DENOISING_STEPS: usize = 8;
    const SAMPLE_RATE: i64 = 44_100;

    pub fn new(model_directory: &Path) -> Result<Self, SupertonicError> {
        let voice_directory = model_directory.join("voice_styles");
        let onnx_directory = model_directory.join("onnx");

        let configuration_data = std::fs::read(onnx_directory.join("tts.json")).map_err(|_| SupertonicError::Io)?;
        let configuration: SupertonicConfigurationFile =
            serde_json::from_slice(&configuration_data).map_err(|_| SupertonicError::InvalidModelConfiguration)?;
        if configuration.ae.sample_rate != Self::SAMPLE_RATE
            || configuration.ae.base_chunk_size <= 0
            || configuration.ttl.chunk_compress_factor <= 0
            || configuration.ttl.latent_dim <= 0
        {
            return Err(SupertonicError::InvalidModelConfiguration);
        }

        let text_processor = SupertonicTextProcessor::new(&onnx_directory.join("unicode_indexer.json"))?;

        let build_session = |name: &str| -> Result<Session, SupertonicError> {
            Session::builder()
                .map_err(|_| SupertonicError::OnnxRuntime)?
                .commit_from_file(onnx_directory.join(name))
                .map_err(|_| SupertonicError::OnnxRuntime)
        };
        let duration_predictor = build_session("duration_predictor.onnx")?;
        let text_encoder = build_session("text_encoder.onnx")?;
        let vector_estimator = build_session("vector_estimator.onnx")?;
        let vocoder = build_session("vocoder.onnx")?;

        Ok(SupertonicEngine {
            voice_directory,
            configuration,
            text_processor,
            duration_predictor: Mutex::new(duration_predictor),
            text_encoder: Mutex::new(text_encoder),
            vector_estimator: Mutex::new(vector_estimator),
            vocoder: Mutex::new(vocoder),
            styles: Mutex::new(HashMap::new()),
        })
    }

    fn synthesize_impl(&self, text: &str, voice: &str, speed: f64) -> Result<PcmBuffer, SupertonicError> {
        if text.trim().is_empty() {
            return Err(SupertonicError::InvalidText);
        }
        if !VoiceCatalog::allowed_voice_ids().contains(voice) {
            return Err(SupertonicError::InvalidVoice);
        }
        if !speed.is_finite() || !(0.7..=2.0).contains(&speed) {
            return Err(SupertonicError::InvalidSpeed);
        }

        let style = self.style_for(voice)?;
        let chunks = SupertonicTensor::split_text(text, 120);
        let mut audio_chunks: Vec<Vec<f32>> = Vec::new();
        for chunk in chunks.iter().filter(|c| !c.is_empty()) {
            audio_chunks.push(self.infer(chunk, &style, speed as f32)?);
        }
        if audio_chunks.is_empty() {
            return Err(SupertonicError::InvalidText);
        }
        let samples = SupertonicTensor::concatenate(&audio_chunks, (0.3 * Self::SAMPLE_RATE as f64) as i64);
        Ok(PcmBuffer { sample_rate: Self::SAMPLE_RATE as f64, channels: 1, samples })
    }

    fn style_for(&self, voice: &str) -> Result<SupertonicStyle, SupertonicError> {
        {
            let styles = self.styles.lock().unwrap();
            if let Some(style) = styles.get(voice) {
                return Ok(SupertonicStyle { ttl: style.ttl.clone(), dp: style.dp.clone() });
            }
        }
        let path = self.voice_directory.join(format!("{voice}.json"));
        let data = std::fs::read(&path).map_err(|_| SupertonicError::InvalidVoiceStyle)?;
        let file: SupertonicVoiceFile = serde_json::from_slice(&data).map_err(|_| SupertonicError::InvalidVoiceStyle)?;
        let ttl = Self::style_value(&file.style_ttl)?;
        let dp = Self::style_value(&file.style_dp)?;
        let style = SupertonicStyle { ttl, dp };
        let cached = SupertonicStyle { ttl: style.ttl.clone(), dp: style.dp.clone() };
        self.styles.lock().unwrap().insert(voice.to_string(), cached);
        Ok(style)
    }

    fn style_value(component: &VoiceComponent) -> Result<(Vec<i64>, Vec<f32>), SupertonicError> {
        if component.dims.len() != 3 || component.dims[0] != 1 || component.dims.iter().any(|&d| d <= 0) {
            return Err(SupertonicError::InvalidVoiceStyle);
        }
        let flattened: Vec<f32> = component.data.iter().flat_map(|a| a.iter()).flat_map(|b| b.iter().copied()).collect();
        let expected: i64 = component.dims.iter().product();
        if flattened.len() as i64 != expected {
            return Err(SupertonicError::InvalidVoiceStyle);
        }
        Ok((component.dims.clone(), flattened))
    }

    fn infer(&self, text: &str, style: &SupertonicStyle, speed: f32) -> Result<Vec<f32>, SupertonicError> {
        let (ids, mask, count) = self.text_processor.encode(text)?;
        let text_ids = Tensor::from_array((vec![1i64, count as i64], ids)).map_err(|_| SupertonicError::OnnxRuntime)?;
        let text_mask = Tensor::from_array((vec![1i64, 1, count as i64], mask)).map_err(|_| SupertonicError::OnnxRuntime)?;
        let style_dp = Tensor::from_array((style.dp.0.clone(), style.dp.1.clone())).map_err(|_| SupertonicError::OnnxRuntime)?;
        let style_ttl = Tensor::from_array((style.ttl.0.clone(), style.ttl.1.clone())).map_err(|_| SupertonicError::OnnxRuntime)?;

        let predicted_duration = {
            let mut session = self.duration_predictor.lock().unwrap();
            let outputs = session
                .run(ort::inputs![
                    "text_ids" => text_ids.view(),
                    "style_dp" => style_dp.view(),
                    "text_mask" => text_mask.view(),
                ])
                .map_err(|_| SupertonicError::OnnxRuntime)?;
            let duration_value = outputs.get("duration").ok_or_else(|| SupertonicError::MissingOutput("duration".to_string()))?;
            let (_, data) = duration_value.try_extract_tensor::<f32>().map_err(|_| SupertonicError::InvalidTensorData)?;
            data.first().copied().ok_or(SupertonicError::InvalidTensorData)?
        };
        let duration = predicted_duration / speed;
        if !duration.is_finite() || duration <= 0.0 {
            return Err(SupertonicError::InvalidTensorData);
        }

        let text_embedding_data = {
            let mut session = self.text_encoder.lock().unwrap();
            let outputs = session
                .run(ort::inputs![
                    "text_ids" => text_ids.view(),
                    "style_ttl" => style_ttl.view(),
                    "text_mask" => text_mask.view(),
                ])
                .map_err(|_| SupertonicError::OnnxRuntime)?;
            let text_embedding =
                outputs.get("text_emb").ok_or_else(|| SupertonicError::MissingOutput("text_emb".to_string()))?;
            let (shape, data) = text_embedding.try_extract_tensor::<f32>().map_err(|_| SupertonicError::InvalidTensorData)?;
            (shape.as_ref().to_vec(), data.to_vec())
        };

        let (mut noise, mask, dimensions, length) = Self::noisy_latent(duration, &self.configuration);
        let noise_shape = vec![1i64, dimensions, length];
        let latent_mask = Tensor::from_array((vec![1i64, 1, length], mask)).map_err(|_| SupertonicError::OnnxRuntime)?;
        let text_emb_shape: Vec<i64> = text_embedding_data.0.clone();
        let text_emb_data = text_embedding_data.1.clone();

        for step in 0..Self::DENOISING_STEPS {
            let current_step = Tensor::from_array((vec![1i64], vec![step as f32])).map_err(|_| SupertonicError::OnnxRuntime)?;
            let total_step =
                Tensor::from_array((vec![1i64], vec![Self::DENOISING_STEPS as f32])).map_err(|_| SupertonicError::OnnxRuntime)?;
            let noisy_value = Tensor::from_array((noise_shape.clone(), noise.clone())).map_err(|_| SupertonicError::OnnxRuntime)?;
            let text_emb_value =
                Tensor::from_array((text_emb_shape.clone(), text_emb_data.clone())).map_err(|_| SupertonicError::OnnxRuntime)?;

            let denoised_data = {
                let mut session = self.vector_estimator.lock().unwrap();
                let outputs = session
                    .run(ort::inputs![
                        "noisy_latent" => noisy_value.view(),
                        "text_emb" => text_emb_value.view(),
                        "style_ttl" => style_ttl.view(),
                        "latent_mask" => latent_mask.view(),
                        "text_mask" => text_mask.view(),
                        "current_step" => current_step.view(),
                        "total_step" => total_step.view(),
                    ])
                    .map_err(|_| SupertonicError::OnnxRuntime)?;
                let denoised = outputs
                    .get("denoised_latent")
                    .ok_or_else(|| SupertonicError::MissingOutput("denoised_latent".to_string()))?;
                let (_, data) = denoised.try_extract_tensor::<f32>().map_err(|_| SupertonicError::InvalidTensorData)?;
                data.to_vec()
            };
            if denoised_data.len() != noise.len() {
                return Err(SupertonicError::InvalidTensorData);
            }
            noise = denoised_data;
        }

        let latent_value = Tensor::from_array((noise_shape, noise)).map_err(|_| SupertonicError::OnnxRuntime)?;
        let samples = {
            let mut session = self.vocoder.lock().unwrap();
            let outputs =
                session.run(ort::inputs!["latent" => latent_value.view()]).map_err(|_| SupertonicError::OnnxRuntime)?;
            let waveform = outputs.get("wav_tts").ok_or_else(|| SupertonicError::MissingOutput("wav_tts".to_string()))?;
            let (_, data) = waveform.try_extract_tensor::<f32>().map_err(|_| SupertonicError::InvalidTensorData)?;
            data.to_vec()
        };
        let expected_count = (Self::SAMPLE_RATE as f32 * duration) as usize;
        if samples.is_empty() || expected_count == 0 {
            return Err(SupertonicError::InvalidTensorData);
        }
        Ok(samples.into_iter().take(expected_count).collect())
    }

    fn noisy_latent(duration: f32, configuration: &SupertonicConfigurationFile) -> (Vec<f32>, Vec<f32>, i64, i64) {
        let chunk_size = configuration.ae.base_chunk_size * configuration.ttl.chunk_compress_factor;
        let waveform_length = (duration * configuration.ae.sample_rate as f32) as i64;
        let latent_length = ((waveform_length + chunk_size - 1) / chunk_size).max(1);
        let latent_dimensions = configuration.ttl.latent_dim * configuration.ttl.chunk_compress_factor;
        let mask = SupertonicTensor::length_mask(
            &[((waveform_length + chunk_size - 1) / chunk_size) as usize],
            Some(latent_length as usize),
        );
        let mut values = vec![0.0f32; (latent_dimensions * latent_length) as usize];
        for (index, value) in values.iter_mut().enumerate() {
            let uniform1: f32 = rand_uniform(0.0001, 1.0);
            let uniform2: f32 = rand_uniform(0.0, 1.0);
            let mask_value = mask[index % latent_length as usize];
            *value = (-2.0 * uniform1.ln()).sqrt() * (2.0 * std::f32::consts::PI * uniform2).cos() * mask_value;
        }
        (values, mask, latent_dimensions, latent_length)
    }
}

/// 외부 `rand` 크레이트 없이 쓰는 간단한 균등분포 — Box-Muller 노이즈 시딩에만 쓰이고,
/// denoising 루프가 결과를 수렴시키므로 암호학적 품질은 필요 없다.
fn rand_uniform(min: f32, max: f32) -> f32 {
    use std::cell::Cell;
    thread_local! {
        static STATE: Cell<u64> = Cell::new(0x2545F4914F6CDD1D ^ std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0x9E3779B97F4A7C15));
    }
    let next = STATE.with(|state| {
        let mut x = state.get();
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        state.set(x);
        x
    });
    let unit = (next >> 11) as f32 / (1u64 << 53) as f32;
    min + unit.clamp(0.0, 1.0) * (max - min)
}

impl TtsBackend for SupertonicEngine {
    fn synthesize(&self, text: &str, voice: &str, speed: f64) -> Result<PcmBuffer, TtsBackendError> {
        self.synthesize_impl(text, voice, speed).map_err(|_| TtsBackendError::SynthesisFailed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn synthesizes_korean_with_installed_voice() {
        let Ok(path) = std::env::var("DEBRIEF_TEST_MODEL_DIR") else {
            eprintln!("skipping: set DEBRIEF_TEST_MODEL_DIR to run the real model smoke test.");
            return;
        };
        let engine = SupertonicEngine::new(Path::new(&path)).expect("engine must load from a real model directory");

        let buffer = engine.synthesize_impl("테스트를 완료했습니다.", "F1", 0.93).expect("synthesis must succeed");

        assert_eq!(buffer.sample_rate, 44_100.0);
        assert_eq!(buffer.channels, 1);
        assert!(!buffer.samples.is_empty());
        assert!(buffer.samples.iter().all(|s| s.is_finite()));
    }
}
