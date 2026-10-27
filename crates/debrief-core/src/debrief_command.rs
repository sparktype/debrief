// 설치·데몬·제어 명령 파싱
use crate::debrief_version::DebriefVersion;
use crate::mcp_speak_tool::CommandError;
use std::collections::HashSet;

/// 프로세스 진입 모드. 에이전트는 `hook`/`mcp`를, 사람은 CLI를 쓴다.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DebriefCommand {
    Install { codex: bool, claude: bool, grok: bool, gemini: bool, repair: bool },
    Uninstall { codex: bool, claude: bool, grok: bool, gemini: bool },
    Daemon,
    Start,
    Stop,
    Restart,
    Status { line: bool },
    Mute(Option<String>),
    Mode(Option<String>),
    Companion(Option<String>),
    Dnd(Option<String>),
    Mic(Option<String>),
    Skip { all: bool },
    Replay(u8),
    Allow(Option<String>),
    Deny(Option<String>),
    Doctor,
    Hook { source: String },
    Mcp,
    Help,
}

impl DebriefCommand {
    pub fn usage_text() -> String {
        format!(
            "debrief {version}\n\n{body}",
            version = DebriefVersion::CURRENT,
            body = concat!(
                "Install / repair (release build, then):\n",
                "  debrief install [--codex] [--claude] [--grok] [--gemini] [--repair]   (Gemini CLI is opt-in)\n",
                "  debrief uninstall [--codex] [--claude] [--grok] [--gemini]\n\n",
                "Service:\n",
                "  debrief daemon\n",
                "  debrief start\n",
                "  debrief stop\n",
                "  debrief restart   (re-launch the daemon; replay history is cleared)\n",
                "  debrief status [--line]   (--line: one line for a status bar)\n",
                "  debrief doctor\n\n",
                "Controls (written to config.json; applied on the next utterance):\n",
                "  debrief mute [on|off|toggle]\n",
                "  debrief mode [normal|focus|quiet|verbose|night]\n",
                "  debrief companion [on|off|toggle]\n",
                "  debrief dnd [on|off|toggle]   (follow macOS Do Not Disturb: at least quiet while it is on)\n",
                "  debrief mic [on|off|toggle]   (at least quiet while another app uses the microphone; never records)\n",
                "  debrief skip [--all]   (stop the current utterance; --all also clears the queue)\n",
                "  debrief replay [n]     (replay the last n utterances, 1-10, default 1)\n",
                "  debrief allow [id] / debrief deny [id]   (answer a relayed Claude Code permission prompt; permissionRelay)\n\n",
                "Agents:\n",
                "  debrief mcp\n",
                "  debrief hook --source <codex|claude|gemini>\n",
                "  debrief help",
            )
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
                Self::require_only(tail, &["--codex", "--claude", "--grok", "--gemini", "--repair"])?;
                Ok(DebriefCommand::Install {
                    codex: tail.iter().any(|a| a == "--codex"),
                    claude: tail.iter().any(|a| a == "--claude"),
                    grok: tail.iter().any(|a| a == "--grok"),
                    gemini: tail.iter().any(|a| a == "--gemini"),
                    repair: tail.iter().any(|a| a == "--repair"),
                })
            }
            "uninstall" => {
                Self::require_only(tail, &["--codex", "--claude", "--grok", "--gemini"])?;
                Ok(DebriefCommand::Uninstall {
                    codex: tail.iter().any(|a| a == "--codex"),
                    claude: tail.iter().any(|a| a == "--claude"),
                    grok: tail.iter().any(|a| a == "--grok"),
                    gemini: tail.iter().any(|a| a == "--gemini"),
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
            "restart" => {
                Self::require_empty(tail, name)?;
                Ok(DebriefCommand::Restart)
            }
            "status" => {
                Self::require_only(tail, &["--line"])?;
                Ok(DebriefCommand::Status { line: !tail.is_empty() })
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
            "dnd" => Ok(DebriefCommand::Dnd(Self::optional_choice(tail, &["on", "off", "toggle"], name)?)),
            "mic" => Ok(DebriefCommand::Mic(Self::optional_choice(tail, &["on", "off", "toggle"], name)?)),
            "skip" => {
                Self::require_only(tail, &["--all"])?;
                if tail.len() > 1 {
                    return Err(CommandError::Usage("skip accepts only --all".to_string()));
                }
                Ok(DebriefCommand::Skip { all: !tail.is_empty() })
            }
            "replay" => {
                let count = match tail {
                    [] => 1,
                    [value] => value
                        .parse::<u8>()
                        .ok()
                        .filter(|n| (1..=crate::daemon_control::Control::MAXIMUM_REPLAY).contains(n))
                        .ok_or_else(|| CommandError::Usage("replay count must be 1-10".to_string()))?,
                    _ => return Err(CommandError::Usage("replay accepts one count".to_string())),
                };
                Ok(DebriefCommand::Replay(count))
            }
            "allow" | "deny" => {
                let id = match tail {
                    [] => None,
                    [id] if crate::permission_relay::PermissionRelay::is_valid_request_id(id) => Some(id.clone()),
                    _ => return Err(CommandError::Usage(format!("{name} accepts one five-letter request id"))),
                };
                Ok(if name == "allow" { DebriefCommand::Allow(id) } else { DebriefCommand::Deny(id) })
            }
            "mcp" => {
                Self::require_empty(tail, name)?;
                Ok(DebriefCommand::Mcp)
            }
            "hook" => {
                let source = Self::required_value("--source", tail)?;
                if !["codex", "claude", "gemini"].contains(&source.as_str()) {
                    return Err(CommandError::Usage("--source must be codex, claude, or gemini".to_string()));
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
    pub const DND_ON: &'static str = "방해금지 연동을 켰습니다.";
    pub const DND_OFF: &'static str = "방해금지 연동을 껐습니다.";
    pub const MIC_ON: &'static str = "마이크 사용 연동을 켰습니다.";
    pub const MIC_OFF: &'static str = "마이크 사용 연동을 껐습니다.";
    pub const STARTED: &'static str = "서비스를 시작했습니다.";
    pub const STOPPED: &'static str = "서비스를 중지했습니다.";
    pub const RESTARTED: &'static str = "서비스를 다시 시작했습니다.";
    pub const ALREADY_RUNNING: &'static str = "이미 실행 중입니다.";
    pub const DAEMON_NOT_RUNNING: &'static str = "debrief 데몬이 실행 중이 아닙니다. `debrief start`로 시작하세요.";
    pub const DAEMON_OUTDATED: &'static str =
        "데몬이 이 명령을 지원하지 않습니다. `debrief stop` 후 `debrief start`로 재시작하세요.";
    pub const LAUNCH_AGENT_MISSING: &'static str = crate::runtime_installer::LAUNCH_AGENT_MISSING_MESSAGE;
    pub const EXECUTABLE_PATH_IS_DIRECTORY: &'static str = crate::runtime_installer::EXECUTABLE_PATH_IS_DIRECTORY_MESSAGE;

    pub const NO_PENDING_PERMISSION: &'static str = "대기 중인 승인 요청이 없습니다.";
    pub const PERMISSION_ALLOWED: &'static str = "승인했습니다.";
    pub const PERMISSION_DENIED: &'static str = "거부했습니다.";
    pub const CANCELLED: &'static str = "취소했습니다.";

    pub fn permission_summary(tool_name: &str, description: &str) -> String {
        format!("{tool_name}: {description}")
    }

    pub fn choose_permission(command: &str) -> String {
        format!("대기 중인 요청이 여럿입니다. id를 지정하세요. 예: debrief {command} <id>")
    }

    pub fn confirm_permission(allow: bool) -> &'static str {
        if allow { "승인할까요? [y/N] " } else { "거부할까요? [y/N] " }
    }

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
        assert_eq!(parse(&["restart"]), Ok(DebriefCommand::Restart));
        assert!(parse(&["restart", "now"]).is_err());
        assert_eq!(parse(&["status"]), Ok(DebriefCommand::Status { line: false }));
        assert_eq!(parse(&["status", "--line"]), Ok(DebriefCommand::Status { line: true }));
        assert!(parse(&["status", "--json"]).is_err());
        assert_eq!(parse(&["doctor"]), Ok(DebriefCommand::Doctor));
        assert_eq!(parse(&["allow"]), Ok(DebriefCommand::Allow(None)));
        assert_eq!(parse(&["deny", "abcde"]), Ok(DebriefCommand::Deny(Some("abcde".to_string()))));
        assert!(parse(&["allow", "abcdl"]).is_err());
        assert!(parse(&["deny", "abcde", "x"]).is_err());
        assert_eq!(parse(&["mute"]), Ok(DebriefCommand::Mute(None)));
        assert_eq!(parse(&["mute", "on"]), Ok(DebriefCommand::Mute(Some("on".to_string()))));
        assert_eq!(parse(&["mute", "off"]), Ok(DebriefCommand::Mute(Some("off".to_string()))));
        assert_eq!(parse(&["mute", "toggle"]), Ok(DebriefCommand::Mute(Some("toggle".to_string()))));
        assert_eq!(parse(&["mode"]), Ok(DebriefCommand::Mode(None)));
        assert_eq!(parse(&["mode", "night"]), Ok(DebriefCommand::Mode(Some("night".to_string()))));
        assert_eq!(parse(&["companion"]), Ok(DebriefCommand::Companion(None)));
        assert_eq!(parse(&["companion", "off"]), Ok(DebriefCommand::Companion(Some("off".to_string()))));
        assert_eq!(parse(&["dnd"]), Ok(DebriefCommand::Dnd(None)));
        assert_eq!(parse(&["dnd", "on"]), Ok(DebriefCommand::Dnd(Some("on".to_string()))));
        assert!(parse(&["dnd", "maybe"]).is_err());
        assert_eq!(parse(&["mic", "off"]), Ok(DebriefCommand::Mic(Some("off".to_string()))));
        assert!(parse(&["mic", "maybe"]).is_err());
        assert_eq!(parse(&["hook", "--source", "claude"]), Ok(DebriefCommand::Hook { source: "claude".to_string() }));
        assert_eq!(parse(&["hook", "--source", "gemini"]), Ok(DebriefCommand::Hook { source: "gemini".to_string() }));
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
        assert_eq!(CliMessages::RESTARTED, "서비스를 다시 시작했습니다.");
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
            Ok(DebriefCommand::Install { codex: false, claude: false, grok: true, gemini: false, repair: false })
        );
        assert_eq!(
            parse(&["install", "--codex", "--claude", "--grok", "--repair"]),
            Ok(DebriefCommand::Install { codex: true, claude: true, grok: true, gemini: false, repair: true })
        );
    }

    #[test]
    fn parses_gemini_flags() {
        assert_eq!(
            parse(&["install", "--gemini", "--repair"]),
            Ok(DebriefCommand::Install { codex: false, claude: false, grok: false, gemini: true, repair: true })
        );
        assert_eq!(
            parse(&["uninstall", "--gemini"]),
            Ok(DebriefCommand::Uninstall { codex: false, claude: false, grok: false, gemini: true })
        );
    }

    #[test]
    fn parses_uninstall_grok_flag() {
        assert_eq!(
            parse(&["uninstall", "--grok"]),
            Ok(DebriefCommand::Uninstall { codex: false, claude: false, grok: true, gemini: false })
        );
    }

    #[test]
    fn parses_skip_and_replay() {
        let parse = |a: &[&str]| DebriefCommand::parse(&a.iter().map(|s| s.to_string()).collect::<Vec<_>>());
        assert_eq!(parse(&["skip"]), Ok(DebriefCommand::Skip { all: false }));
        assert_eq!(parse(&["skip", "--all"]), Ok(DebriefCommand::Skip { all: true }));
        assert!(parse(&["skip", "--now"]).is_err());
        assert_eq!(parse(&["replay"]), Ok(DebriefCommand::Replay(1)));
        assert_eq!(parse(&["replay", "3"]), Ok(DebriefCommand::Replay(3)));
        assert_eq!(parse(&["replay", "10"]), Ok(DebriefCommand::Replay(10)));
        for bad in [["replay", "0"], ["replay", "11"], ["replay", "x"]] {
            assert!(parse(&bad[..]).is_err(), "{bad:?}");
        }
        assert!(parse(&["replay", "1", "2"]).is_err());
        assert!(DebriefCommand::usage_text().contains("debrief replay [n]"));
    }
}
