// debrief CLI 진입점 — 서브커맨드 파싱과 실행을 연결한다
use debrief_core::{
    current_executable_url, CliMessages, ConfigurationCommands, Control, DebriefCommand, DebriefPaths,
    Diagnostics, HookCommandRunner, HostSource, LiveMcpInstallRunner, McpServer,
    ModelInstaller, ModelManifest, ProcessLaunchctlRunner, ResidentService, ResidentServiceError,
    PermissionRelay, PermissionRelayError, RuntimeInstaller, RuntimeInstallerError, ServiceStartResult, UnixSocketClient, UnixSocketError, UreqModelDownloader,
};
use debrief_tts::{AudioPlayer, SupertonicEngine};
use std::collections::HashSet;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

fn main() {
    let arguments: Vec<String> = std::env::args().skip(1).collect();
    let command = match DebriefCommand::parse(&arguments) {
        Ok(command) => command,
        Err(error) => {
            eprintln!("error: {error:?}\n\n{}", DebriefCommand::usage_text());
            std::process::exit(64);
        }
    };

    let home = std::env::var("DEBRIEF_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| dirs_home());

    match command {
        DebriefCommand::Daemon => run_daemon(&home),
        other => std::process::exit(run_command(other, &home)),
    }
}

/// 상주형 헤드리스 데몬. 신호(SIGTERM/SIGINT)는 서비스를 멈추고 소켓·pid를 지운 뒤 0으로 종료한다.
fn run_daemon(home: &std::path::Path) -> ! {
    if debrief_core::is_foreign_host_running(home, &|pid| unsafe { libc::kill(pid, 0) == 0 }) {
        println!("{}", CliMessages::ALREADY_RUNNING);
        std::process::exit(0);
    }

    let service: Arc<ResidentService<SupertonicEngine, AudioPlayer>> = Arc::new(ResidentService::new(
        home.to_path_buf(),
        Box::new(ResidentService::<SupertonicEngine, AudioPlayer>::default_model_directory_provider),
        Box::new(|model_directory| SupertonicEngine::new(model_directory).map_err(|_| debrief_core::ProvisioningFailed)),
        Box::new(AudioPlayer::new),
        None,
        None,
    ));

    match service.start() {
        Ok(()) => {}
        Err(ResidentServiceError::AlreadyRunning) => {
            println!("{}", CliMessages::ALREADY_RUNNING);
            std::process::exit(0);
        }
        Err(ResidentServiceError::ModelUnavailable) => match service.park_without_socket("모델을 사용할 수 없습니다.") {
            Ok(()) => {}
            Err(ResidentServiceError::AlreadyRunning) => {
                println!("{}", CliMessages::ALREADY_RUNNING);
                std::process::exit(0);
            }
            Err(error) => {
                let message = format!("{error:?}");
                let _ = Diagnostics::new(home).record_error("daemon", "start_failed", &message);
                eprintln!("{}", CliMessages::start_failed("daemon/start_failed"));
                std::process::exit(1);
            }
        },
        Err(error) => {
            let message = format!("{error:?}");
            let _ = Diagnostics::new(home).record_error("daemon", "start_failed", &message);
            eprintln!("{}", CliMessages::start_failed("daemon/start_failed"));
            std::process::exit(1);
        }
    }

    install_termination_handler();
    let watcher_service = service.clone();
    std::thread::spawn(move || {
        loop {
            if TERMINATION_REQUESTED.load(Ordering::SeqCst) {
                watcher_service.stop(true);
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
    });

    service.wait_until_stopped();
    if let Some(failure) = service.consume_run_failure() {
        let message = format!("{failure:?}");
        let _ = Diagnostics::new(home).record_error("daemon", "run_failed", &message);
        eprintln!("{}", CliMessages::daemon_run_failed("daemon/run_failed"));
    }
    std::process::exit(0);
}

static TERMINATION_REQUESTED: AtomicBool = AtomicBool::new(false);

extern "C" fn handle_termination_signal(_signal: libc::c_int) {
    TERMINATION_REQUESTED.store(true, Ordering::SeqCst);
}

/// SIGTERM/SIGINT를 신호 안전한 플래그로만 받고, 실제 정리(소켓 종료, pid 제거)는 별도 와처
/// 스레드에서 수행한다 — 시그널 핸들러 안에서 락을 잡지 않기 위함이다.
fn install_termination_handler() {
    // SAFETY: `handle_termination_signal` has the `extern "C" fn(c_int)` signature `signal`
    // expects, and only stores to an `AtomicBool` — safe to call from a signal handler context.
    unsafe {
        libc::signal(libc::SIGTERM, handle_termination_signal as *const () as usize);
        libc::signal(libc::SIGINT, handle_termination_signal as *const () as usize);
    }
}

fn dirs_home() -> PathBuf {
    std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("/"))
}

/// 플래그가 없으면 Codex·Claude·Grok에 더해, `gemini_by_default`면 Gemini도 고른다(Gemini는 옵트인).
fn selected_hosts(codex: bool, claude: bool, grok: bool, gemini: bool, gemini_by_default: bool) -> HashSet<HostSource> {
    if !codex && !claude && !grok && !gemini {
        let mut hosts: HashSet<HostSource> = [HostSource::Codex, HostSource::Claude, HostSource::Grok].into_iter().collect();
        if gemini_by_default {
            hosts.insert(HostSource::Gemini);
        }
        return hosts;
    }
    let mut hosts = HashSet::new();
    if gemini {
        hosts.insert(HostSource::Gemini);
    }
    if codex {
        hosts.insert(HostSource::Codex);
    }
    if claude {
        hosts.insert(HostSource::Claude);
    }
    if grok {
        hosts.insert(HostSource::Grok);
    }
    hosts
}

fn make_runtime<'a>(
    home: &std::path::Path,
    source_executable: PathBuf,
    launchctl: &'a ProcessLaunchctlRunner,
) -> RuntimeInstaller<'a, ModelInstaller<UreqModelDownloader>> {
    let paths = DebriefPaths::for_home(home);
    let model_installer =
        ModelInstaller::new(paths.models_directory.clone(), ModelManifest::supertonic3(), UreqModelDownloader::new());
    // SAFETY: getuid() takes no arguments and cannot fail.
    let user_id = unsafe { libc::getuid() };
    RuntimeInstaller::new(home.to_path_buf(), source_executable, model_installer, launchctl, user_id)
}

fn print_preserved_files(paths: &[String]) {
    for path in paths {
        println!("preserved modified file: {path}");
    }
}

fn run_command(command: DebriefCommand, home: &std::path::Path) -> i32 {
    match command {
        DebriefCommand::Help => {
            println!("{}", DebriefCommand::usage_text());
            0
        }
        DebriefCommand::Install { codex, claude, grok, gemini, repair } => {
            let paths = DebriefPaths::for_home(home);
            // 이미 Gemini를 배선했다면 플래그 없는 `install --repair`도 함께 고친다.
            let gemini_installed = debrief_core::InstallManifest::load(&paths.install_manifest_url)
                .is_ok_and(|manifest| manifest.hooks.iter().any(|owned| owned.host == HostSource::Gemini));
            let hosts = selected_hosts(codex, claude, grok, gemini, gemini_installed);
            let source_executable = current_executable_url();
            let launchctl = ProcessLaunchctlRunner::new();
            let runtime = make_runtime(home, source_executable, &launchctl);
            match runtime.install(&hosts, repair) {
                Ok(result) => {
                    let _ = Diagnostics::new(home).clear_current_error();
                    let mut names: Vec<&str> = hosts.iter().map(|h| h.as_str()).collect();
                    names.sort();
                    println!("installed: {}", names.join(","));
                    println!("binary: {}", paths.executable_url.display());
                    if result.codex_review_required {
                        println!("Codex에서 /hooks를 열어 debrief hook을 검토하고 신뢰하세요.");
                    }
                    print_preserved_files(&result.preserved_modified_files);
                    debrief_core::install_chime::InstallChime::try_play(home);
                    0
                }
                Err(error) => {
                    let detail = format!("{error:?}");
                    let _ = Diagnostics::new(home).record_error("app", "command_failed", &detail);
                    eprintln!("{}", CliMessages::command_failed("app/command_failed"));
                    1
                }
            }
        }
        DebriefCommand::Uninstall { codex, claude, grok, gemini } => {
            let hosts = selected_hosts(codex, claude, grok, gemini, true);
            let source_executable = current_executable_url();
            let launchctl = ProcessLaunchctlRunner::new();
            let runtime = make_runtime(home, source_executable, &launchctl);
            match runtime.uninstall(&hosts) {
                Ok(result) => {
                    let mut names: Vec<&str> = hosts.iter().map(|h| h.as_str()).collect();
                    names.sort();
                    println!("uninstalled: {}", names.join(","));
                    print_preserved_files(&result.preserved_modified_files);
                    0
                }
                Err(error) => {
                    let detail = format!("{error:?}");
                    let _ = Diagnostics::new(home).record_error("app", "command_failed", &detail);
                    eprintln!("{}", CliMessages::command_failed("app/command_failed"));
                    1
                }
            }
        }
        DebriefCommand::Allow(id) => run_permission_verdict(home, id.as_deref(), true),
        DebriefCommand::Deny(id) => run_permission_verdict(home, id.as_deref(), false),
        DebriefCommand::Skip { all } => run_control(home, if all { Control::SkipAll } else { Control::Skip }),
        DebriefCommand::Replay(count) => run_control(home, Control::Replay(count)),
        DebriefCommand::Start => run_start(home),
        DebriefCommand::Stop => run_stop(home),
        DebriefCommand::Restart => run_restart(home),
        DebriefCommand::Status { line: false } => {
            println!("{}", Diagnostics::new(home).status_text());
            0
        }
        DebriefCommand::Status { line: true } => {
            let reachable = UnixSocketClient::new(DebriefPaths::for_home(home).socket_url).is_reachable();
            println!("{}", Diagnostics::new(home).status_line(reachable));
            0
        }
        DebriefCommand::Doctor => {
            let diagnostics = Diagnostics::new(home);
            println!("{}", diagnostics.doctor_report_text());
            if diagnostics.doctor().iter().any(|f| !f.ok) {
                1
            } else {
                0
            }
        }
        DebriefCommand::Mute(action) => print_configuration_result(|| {
            let updated = ConfigurationCommands::apply_mute(action.as_deref(), home)?;
            println!("{}", if updated.muted { CliMessages::MUTED } else { CliMessages::UNMUTED });
            Ok(())
        }),
        DebriefCommand::Mode(action) => print_configuration_result(|| {
            let updated = ConfigurationCommands::apply_mode(action.as_deref(), home)?;
            if action.is_none() {
                println!("{}", CliMessages::current_mode(updated.mode.as_str()));
            } else {
                println!("{}", CliMessages::mode_set(updated.mode.as_str()));
            }
            Ok(())
        }),
        DebriefCommand::Companion(action) => print_configuration_result(|| {
            let updated = ConfigurationCommands::apply_companion(action.as_deref(), home)?;
            println!("{}", if updated.companion_enabled { CliMessages::COMPANION_ON } else { CliMessages::COMPANION_OFF });
            Ok(())
        }),
        DebriefCommand::Dnd(action) => print_configuration_result(|| {
            let updated = ConfigurationCommands::apply_dnd(action.as_deref(), home)?;
            println!("{}", if updated.dnd_sync { CliMessages::DND_ON } else { CliMessages::DND_OFF });
            Ok(())
        }),
        DebriefCommand::Mic(action) => print_configuration_result(|| {
            let updated = ConfigurationCommands::apply_mic(action.as_deref(), home)?;
            println!("{}", if updated.mic_sync { CliMessages::MIC_ON } else { CliMessages::MIC_OFF });
            Ok(())
        }),
        DebriefCommand::Hook { source } => {
            let Some(host) = (match source.as_str() {
                "codex" => Some(HostSource::Codex),
                "claude" => Some(HostSource::Claude),
                "grok" => Some(HostSource::Grok),
                "gemini" => Some(HostSource::Gemini),
                _ => None,
            }) else {
                eprintln!("error: --source는 codex, claude, grok, gemini 중 하나여야 합니다.");
                return 64;
            };
            let mut input = Vec::new();
            if std::io::Read::read_to_end(&mut std::io::stdin(), &mut input).is_err() {
                return 1;
            }
            let running_inside_grok = std::env::var_os("GROK_HOOK_EVENT").is_some();
            let output = HookCommandRunner::run_with(&input, host, home, running_inside_grok);
            let _ = std::io::stdout().write_all(&output);
            0
        }
        DebriefCommand::Mcp => {
            let paths = DebriefPaths::for_home(home);
            let sink = UnixSocketClient::new(paths.socket_url);
            let install_runner = LiveMcpInstallRunner::new(home.to_path_buf(), current_executable_url());
            let server = McpServer::new(home.to_path_buf(), sink, install_runner);
            if server.permission_relay_enabled() {
                spawn_permission_verdict_writer(paths.permissions_directory);
            }
            server.run(std::io::stdin(), std::io::stdout());
            0
        }
        DebriefCommand::Daemon => unreachable!("handled in main() before run_command"),
    }
}

fn print_configuration_result(body: impl FnOnce() -> Result<(), debrief_core::ConfigurationCommandError>) -> i32 {
    match body() {
        Ok(()) => 0,
        Err(error) => {
            let detail = format!("{error:?}");
            eprintln!("{}", CliMessages::config_save_failed(&detail));
            1
        }
    }
}

fn run_start(home: &std::path::Path) -> i32 {
    let source_executable = current_executable_url();
    let launchctl = ProcessLaunchctlRunner::new();
    let runtime = make_runtime(home, source_executable, &launchctl);
    match runtime.start() {
        Ok(ServiceStartResult::AlreadyRunning) => {
            println!("{}", CliMessages::ALREADY_RUNNING);
            0
        }
        Ok(ServiceStartResult::Started) => {
            println!("{}", CliMessages::STARTED);
            0
        }
        Err(RuntimeInstallerError::LaunchAgentMissing) => {
            eprintln!("{}", CliMessages::LAUNCH_AGENT_MISSING);
            1
        }
        Err(error) => {
            let _ = Diagnostics::new(home).record_error("daemon", "start_failed", &format!("{error:?}"));
            eprintln!("{}", CliMessages::start_failed("daemon/start_failed"));
            1
        }
    }
}

fn run_restart(home: &std::path::Path) -> i32 {
    let launchctl = ProcessLaunchctlRunner::new();
    let runtime = make_runtime(home, current_executable_url(), &launchctl);
    match runtime.restart() {
        Ok(()) => {
            println!("{}", CliMessages::RESTARTED);
            0
        }
        Err(RuntimeInstallerError::LaunchAgentMissing) => {
            eprintln!("{}", CliMessages::LAUNCH_AGENT_MISSING);
            1
        }
        Err(error) => {
            let _ = Diagnostics::new(home).record_error("daemon", "start_failed", &format!("{error:?}"));
            eprintln!("{}", CliMessages::start_failed("daemon/start_failed"));
            1
        }
    }
}

fn run_stop(home: &std::path::Path) -> i32 {
    let source_executable = current_executable_url();
    let launchctl = ProcessLaunchctlRunner::new();
    let runtime = make_runtime(home, source_executable, &launchctl);
    match runtime.stop() {
        Ok(()) => {
            println!("{}", CliMessages::STOPPED);
            0
        }
        Err(error) => {
            let _ = Diagnostics::new(home).record_error("daemon", "stop_failed", &format!("{error:?}"));
            eprintln!("{}", CliMessages::stop_failed("daemon/stop_failed"));
            1
        }
    }
}

fn run_control(home: &std::path::Path, control: Control) -> i32 {
    match UnixSocketClient::new(DebriefPaths::for_home(home).socket_url).send_control(&control) {
        Ok(()) => 0,
        // 구버전 데몬은 제어 프레임을 발화로 읽다 실패해 NAK를 돌려준다.
        Err(UnixSocketError::Rejected) => {
            eprintln!("{}", CliMessages::DAEMON_OUTDATED);
            1
        }
        Err(_) => {
            eprintln!("{}", CliMessages::DAEMON_NOT_RUNNING);
            1
        }
    }
}

/// CLI가 남긴 판정을 이 MCP 프로세스의 호스트(Claude Code)에 권한 알림으로 돌려준다.
fn spawn_permission_verdict_writer(directory: PathBuf) {
    std::thread::spawn(move || {
        let relay = PermissionRelay::new(directory);
        loop {
            for (request_id, behavior) in relay.take_verdicts(std::process::id(), debrief_core::session_state::now_seconds()) {
                let notification = PermissionRelay::verdict_notification(&request_id, behavior);
                debrief_core::write_frame(&mut std::io::stdout(), &notification, debrief_core::McpWireFormat::NewlineDelimited);
            }
            std::thread::sleep(std::time::Duration::from_millis(300));
        }
    });
}

fn run_permission_verdict(home: &std::path::Path, request_id: Option<&str>, allow: bool) -> i32 {
    let relay = PermissionRelay::new(DebriefPaths::for_home(home).permissions_directory);
    let now = debrief_core::session_state::now_seconds();
    let command = if allow { "allow" } else { "deny" };
    let request = match relay.target(request_id, now) {
        Ok((request, false)) => request,
        Ok((request, true)) => {
            // id 없이 골랐으면 무엇을 판정하는지 보여 주고 한 번 더 묻는다.
            println!("{}", CliMessages::permission_summary(&request.tool_name, &request.description));
            if !request.input_preview.is_empty() {
                println!("{}", request.input_preview);
            }
            print!("{}", CliMessages::confirm_permission(allow));
            let _ = std::io::stdout().flush();
            let mut answer = String::new();
            let _ = std::io::stdin().read_line(&mut answer);
            if !matches!(answer.trim(), "y" | "Y" | "yes") {
                println!("{}", CliMessages::CANCELLED);
                return 1;
            }
            request
        }
        Err(PermissionRelayError::Ambiguous(pending)) => {
            for request in pending {
                println!("  {}  {}", request.request_id, CliMessages::permission_summary(&request.tool_name, &request.description));
            }
            eprintln!("{}", CliMessages::choose_permission(command));
            return 1;
        }
        Err(PermissionRelayError::NotPending) => {
            eprintln!("{}", CliMessages::NO_PENDING_PERMISSION);
            return 1;
        }
        Err(error) => {
            eprintln!("error: {error:?}");
            return 1;
        }
    };
    match relay.decide(&request.request_id, allow, now) {
        Ok(_) => {
            println!("{}", if allow { CliMessages::PERMISSION_ALLOWED } else { CliMessages::PERMISSION_DENIED });
            0
        }
        Err(error) => {
            eprintln!("error: {error:?}");
            1
        }
    }
}
