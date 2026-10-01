pub mod configuration;
pub mod debrief_version;
pub mod diagnostics;
pub mod embedded_templates;
pub mod hook_adapter;
pub mod hook_engine;
pub mod hook_event;
pub mod host_installer;
pub mod host_mcp_status;
pub mod install_manifest;
pub mod launch_agent_control;
pub mod mcp_install_tool;
pub mod mcp_speak_tool;
pub mod mcp_toml_config;
pub mod mode_policy;
pub mod model_installer;
pub mod model_manifest;
pub mod paths;
pub mod runtime_installer;
pub mod session_voice_rotation;
pub mod speech_emotion;
pub mod speech_envelope;
pub mod speech_lane;
pub mod speech_queue;
pub mod speech_request;
pub mod tts_backend;
pub mod unix_socket;
pub mod voice_catalog;

pub use configuration::{ConfigurationCommandError, ConfigurationCommands, DebriefConfiguration, DebriefMode};
pub use debrief_version::DebriefVersion;
pub use diagnostics::{CurrentError, DaemonProcessState, DiagnosticFinding, Diagnostics, StatusSnapshot};
pub use embedded_templates::{EmbeddedHookEntry, EmbeddedHookHandler, EmbeddedTemplates};
pub use hook_adapter::{HookAdapter, HookAdapterError};
pub use hook_engine::{HookEngine, HookResult};
pub use hook_event::{HookEvent, HookEventName, HostSource};
pub use host_installer::{HostInstallResult, HostInstaller, HostInstallerError};
pub use host_mcp_status::{HostMcpProbe, HostMcpState, HostMcpStatus};
pub use install_manifest::{
    AtomicInstallerFile, InstallManifest, InstallManifestError, InstallerDigest, OwnedHook, OwnedInstalledFile,
    OwnedRuntimeFile,
};
pub use launch_agent_control::{LaunchAgentControl, LaunchctlError, LaunchctlRunning, ProcessLaunchctlRunner};
pub use mcp_install_tool::{McpInstallArguments, McpInstallRunning, McpInstallTool};
pub use mcp_speak_tool::{CommandError, McpSpeakArguments, McpSpeakTool, McpToolCallResult, SpeechSink};
pub use mcp_toml_config::McpTomlConfig;
pub use mode_policy::ModePolicy;
pub use model_installer::{
    InstalledModel, ModelDownloading, ModelInstaller, ModelInstallerError, UreqModelDownloader,
};
pub use model_manifest::{ModelAsset, ModelManifest, ModelManifestError};
pub use paths::DebriefPaths;
pub use runtime_installer::{RuntimeInstaller, RuntimeInstallerError, RuntimeModelInstalling, ServiceStartResult};
pub use session_voice_rotation::{SessionVoiceError, SessionVoiceRotation, SessionVoiceStore};
pub use speech_emotion::{EmotionProsody, SpeechEmotion};
pub use speech_envelope::{EnvelopeError, SpeechEnvelope};
pub use speech_lane::SpeechLane;
pub use speech_queue::{QueueDecision, SpeechQueue};
pub use speech_request::{SpeechPriority, SpeechRequest};
pub use tts_backend::{PcmBuffer, TtsBackend, TtsBackendError};
pub use unix_socket::{is_recoverable_accept_error, UnixSocketClient, UnixSocketError, UnixSocketServer};
pub use voice_catalog::{VoiceAssignment, VoiceCatalog};
