// 설치·데몬·제어 명령 파싱
use crate::debrief_version::DebriefVersion;
use crate::mcp_speak_tool::CommandError;
use std::collections::HashSet;

/// 프로세스 진입 모드. 에이전트는 `hook`/`mcp`를, 사람은 CLI를 쓴다.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DebriefCommand {
    Install { codex: bool, claude: bool, grok: bool, repair: bool },
    Uninstall { codex: bool, claude: bool, grok: bool },
    Daemon,
    Start,
    Stop,
    Status,
    Mute(Option<String>),
    Mode(Option<String>),
    Companion(Option<String>),
    Doctor,
    Hook { source: String },
    Mcp,
    Help,
}

impl DebriefCommand {
    pub fn usage_text() -> String {
        format!(
            "debrief {}\n\n\
Install / repair (release build, then):\n\
  debrief install [--codex] [--claude] [--grok] [--repair]\n\
  debrief uninstall [--codex] [--claude] [--grok]\n\n\
Service:\n\
  debrief daemon\n\
  debrief start\n\
  debrief stop\n\
  debrief status\n\
  debrief doctor\n\n\
Controls (written to config.json; applied on the next utterance):\n\
  debrief mute [on|off|toggle]\n\
  debrief mode [normal|focus|quiet|verbose|night]\n\
  debrief companion [on|off|toggle]\n\n\
Agents:\n\
  debrief mcp\n\
  debrief hook --source <codex|claude>\n\
  debrief help",
            DebriefVersion::CURRENT
        )
    }

    pub fn parse(arguments: &[String]) -> Result<DebriefCommand, CommandError> {
        let Some(name) = arguments.first() else { return Ok(DebriefCommand::Help) };
        let tail = &arguments[1..];

        match name.as_str() {
            "--help" | "-h" | "help" => {
                if !tail.is_empty() {
                    return Err(CommandError::Usage("help accepts no arguments".to_string()));
                }
                Ok(DebriefCommand::Help)
            }
            "install" => {
                Self::require_only(tail, &["--codex", "--claude", "--grok", "--repair"])?;
                Ok(DebriefCommand::Install {
                    codex: tail.iter().any(|a| a == "--codex"),
                    claude: tail.iter().any(|a| a == "--claude"),
                    grok: tail.iter().any(|a| a == "--grok"),
                    repair: tail.iter().any(|a| a == "--repair"),
                })
            }
            "uninstall" => {
                Self::require_only(tail, &["--codex", "--claude", "--grok"])?;
                Ok(DebriefCommand::Uninstall {
                    codex: tail.iter().any(|a| a == "--codex"),
                    claude: tail.iter().any(|a| a == "--claude"),
                    grok: tail.iter().any(|a| a == "--grok"),
                })
            }
            "daemon" => {
                Self::require_empty(tail, name)?;
                Ok(DebriefCommand::Daemon)
            }
            "start" => {
                Self::require_empty(tail, name)?;
                Ok(DebriefCommand::Start)
            }
            "stop" => {
                Self::require_empty(tail, name)?;
                Ok(DebriefCommand::Stop)
            }
            "status" => {
                Self::require_empty(tail, name)?;
                Ok(DebriefCommand::Status)
            }
            "doctor" => {
                Self::require_empty(tail, name)?;
                Ok(DebriefCommand::Doctor)
            }
            "mute" => Ok(DebriefCommand::Mute(Self::optional_choice(tail, &["on", "off", "toggle"], name)?)),
            "mode" => {
                let allowed: HashSet<&str> = ["normal", "focus", "quiet", "verbose", "night"].into_iter().collect();
                Ok(DebriefCommand::Mode(Self::optional_choice_set(tail, &allowed, name)?))
            }
            "companion" => Ok(DebriefCommand::Companion(Self::optional_choice(tail, &["on", "off", "toggle"], name)?)),
            "mcp" => {
                Self::require_empty(tail, name)?;
                Ok(DebriefCommand::Mcp)
            }
            "hook" => {
                let source = Self::required_value("--source", tail)?;
                if source != "codex" && source != "claude" {
                    return Err(CommandError::Usage("--source must be codex or claude".to_string()));
                }
                Self::require_flag_pairs(tail, &["--source"])?;
                Ok(DebriefCommand::Hook { source })
            }
            other => Err(CommandError::Usage(format!("unknown command: {other}"))),
        }
    }

    fn optional_choice(arguments: &[String], allowed: &[&str], command: &str) -> Result<Option<String>, CommandError> {
        Self::optional_choice_set(arguments, &allowed.iter().copied().collect(), command)
    }

    fn optional_choice_set(
        arguments: &[String],
        allowed: &HashSet<&str>,
        command: &str,
    ) -> Result<Option<String>, CommandError> {
        if arguments.is_empty() {
            return Ok(None);
        }
        if arguments.len() != 1 || !allowed.contains(arguments[0].as_str()) {
            return Err(CommandError::Usage(format!("unsupported {command} argument")));
        }
        Ok(Some(arguments[0].clone()))
    }

    fn require_empty(arguments: &[String], command: &str) -> Result<(), CommandError> {
        if !arguments.is_empty() {
            return Err(CommandError::Usage(format!("{command} accepts no arguments")));
        }
        Ok(())
    }

    fn require_only(arguments: &[String], flags: &[&str]) -> Result<(), CommandError> {
        if !arguments.iter().all(|a| flags.contains(&a.as_str())) {
            return Err(CommandError::Usage("unsupported option".to_string()));
        }
        Ok(())
    }

    fn required_value(flag: &str, arguments: &[String]) -> Result<String, CommandError> {
        let Some(index) = arguments.iter().position(|a| a == flag) else {
            return Err(CommandError::Usage(format!("missing required {flag}")));
        };
        let Some(value) = arguments.get(index + 1) else {
            return Err(CommandError::Usage(format!("missing required {flag}")));
        };
        if value.starts_with("--") {
            return Err(CommandError::Usage(format!("missing required {flag}")));
        }
        Ok(value.clone())
    }

    fn require_flag_pairs(arguments: &[String], flags: &[&str]) -> Result<(), CommandError> {
        if !arguments.len().is_multiple_of(2) {
            return Err(CommandError::Usage("invalid options".to_string()));
        }
        for pair in arguments.chunks(2) {
            if !flags.contains(&pair[0].as_str()) || pair[1].starts_with("--") {
                return Err(CommandError::Usage("unsupported option".to_string()));
            }
        }
        Ok(())
    }
}

/// CLI가 출력하는 한국어 문장들. 도움말 텍스트는 영어로 유지한다.
pub struct CliMessages;

impl CliMessages {
    pub const MUTED: &'static str = "음소거했습니다.";
    pub const UNMUTED: &'static str = "음소거를 해제했습니다.";
    pub const COMPANION_ON: &'static str = "도우미 음성을 켰습니다.";
    pub const COMPANION_OFF: &'static str = "도우미 음성을 껐습니다.";
    pub const STARTED: &'static str = "서비스를 시작했습니다.";
    pub const STOPPED: &'static str = "서비스를 중지했습니다.";
    pub const ALREADY_RUNNING: &'static str = "이미 실행 중입니다.";
    pub const LAUNCH_AGENT_MISSING: &'static str = crate::runtime_installer::LAUNCH_AGENT_MISSING_MESSAGE;
    pub const EXECUTABLE_PATH_IS_DIRECTORY: &'static str = crate::runtime_installer::EXECUTABLE_PATH_IS_DIRECTORY_MESSAGE;

    pub fn current_mode(mode: &str) -> String {
        format!("현재 모드는 {mode}입니다.")
    }

    pub fn mode_set(mode: &str) -> String {
        format!("모드를 {mode}로 설정했습니다.")
    }

    pub fn start_failed(reason: &str) -> String {
        format!("서비스를 시작하지 못했습니다. {reason}")
    }

    pub fn stop_failed(reason: &str) -> String {
        format!("서비스를 중지하지 못했습니다. {reason}")
    }

    pub fn config_save_failed(reason: &str) -> String {
        format!("설정을 저장하지 못했습니다. {reason}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<DebriefCommand, CommandError> {
        DebriefCommand::parse(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn empty_arguments_print_help() {
        assert_eq!(parse(&[]), Ok(DebriefCommand::Help));
    }

    #[test]
    fn help_still_available() {
        assert_eq!(parse(&["help"]), Ok(DebriefCommand::Help));
        assert_eq!(parse(&["-h"]), Ok(DebriefCommand::Help));
    }

    #[test]
    fn parses_daemon_controls() {
        assert_eq!(parse(&["daemon"]), Ok(DebriefCommand::Daemon));
        assert_eq!(parse(&["start"]), Ok(DebriefCommand::Start));
        assert_eq!(parse(&["stop"]), Ok(DebriefCommand::Stop));
        assert_eq!(parse(&["status"]), Ok(DebriefCommand::Status));
        assert_eq!(parse(&["doctor"]), Ok(DebriefCommand::Doctor));
        assert_eq!(parse(&["mute"]), Ok(DebriefCommand::Mute(None)));
        assert_eq!(parse(&["mute", "on"]), Ok(DebriefCommand::Mute(Some("on".to_string()))));
        assert_eq!(parse(&["mute", "off"]), Ok(DebriefCommand::Mute(Some("off".to_string()))));
        assert_eq!(parse(&["mute", "toggle"]), Ok(DebriefCommand::Mute(Some("toggle".to_string()))));
        assert_eq!(parse(&["mode"]), Ok(DebriefCommand::Mode(None)));
        assert_eq!(parse(&["mode", "night"]), Ok(DebriefCommand::Mode(Some("night".to_string()))));
        assert_eq!(parse(&["companion"]), Ok(DebriefCommand::Companion(None)));
        assert_eq!(parse(&["companion", "off"]), Ok(DebriefCommand::Companion(Some("off".to_string()))));
        assert_eq!(parse(&["hook", "--source", "claude"]), Ok(DebriefCommand::Hook { source: "claude".to_string() }));
    }

    #[test]
    fn rejects_menubar_and_speak() {
        for name in ["menubar", "speak"] {
            assert!(parse(&[name]).is_err());
        }
    }

    #[test]
    fn rejects_invalid_control_arguments() {
        assert!(parse(&["daemon", "--extra"]).is_err());
        assert!(parse(&["mute", "maybe"]).is_err());
        assert!(parse(&["mode", "loud"]).is_err());
        assert!(parse(&["companion", "maybe"]).is_err());
    }

    #[test]
    fn control_messages_match_the_cli_contract() {
        assert_eq!(CliMessages::MUTED, "음소거했습니다.");
        assert_eq!(CliMessages::UNMUTED, "음소거를 해제했습니다.");
        assert_eq!(CliMessages::COMPANION_ON, "도우미 음성을 켰습니다.");
        assert_eq!(CliMessages::COMPANION_OFF, "도우미 음성을 껐습니다.");
        assert_eq!(CliMessages::current_mode("night"), "현재 모드는 night입니다.");
        assert_eq!(CliMessages::mode_set("focus"), "모드를 focus로 설정했습니다.");
        assert_eq!(CliMessages::STARTED, "서비스를 시작했습니다.");
        assert_eq!(CliMessages::STOPPED, "서비스를 중지했습니다.");
        assert_eq!(CliMessages::ALREADY_RUNNING, "이미 실행 중입니다.");
        assert_eq!(CliMessages::LAUNCH_AGENT_MISSING, "LaunchAgent가 없습니다. debrief install을 실행하세요.");
        assert_eq!(CliMessages::start_failed("boom"), "서비스를 시작하지 못했습니다. boom");
        assert_eq!(CliMessages::stop_failed("boom"), "서비스를 중지하지 못했습니다. boom");
        assert_eq!(CliMessages::config_save_failed("boom"), "설정을 저장하지 못했습니다. boom");
        assert_eq!(CliMessages::EXECUTABLE_PATH_IS_DIRECTORY, "실행 파일 경로가 디렉터리입니다. ~/.local/bin/debrief 를 비운 뒤 다시 설치하세요.");
        assert!(!DebriefCommand::usage_text().to_lowercase().contains("menu bar"));
        assert!(!DebriefCommand::usage_text().contains("menubar"));
    }

    #[test]
    fn parses_mcp() {
        assert_eq!(parse(&["mcp"]), Ok(DebriefCommand::Mcp));
    }

    #[test]
    fn mcp_rejects_extra_arguments() {
        assert!(parse(&["mcp", "--extra"]).is_err());
    }

    #[test]
    fn parses_install_grok_flag() {
        assert_eq!(
            parse(&["install", "--grok"]),
            Ok(DebriefCommand::Install { codex: false, claude: false, grok: true, repair: false })
        );
        assert_eq!(
            parse(&["install", "--codex", "--claude", "--grok", "--repair"]),
            Ok(DebriefCommand::Install { codex: true, claude: true, grok: true, repair: true })
        );
    }

    #[test]
    fn parses_uninstall_grok_flag() {
        assert_eq!(
            parse(&["uninstall", "--grok"]),
            Ok(DebriefCommand::Uninstall { codex: false, claude: false, grok: true })
        );
    }
}
