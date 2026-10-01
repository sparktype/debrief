// debrief CLI 진입점 — 서브커맨드 파싱과 실행을 연결한다
use debrief_core::{
    current_executable_url, CliMessages, ConfigurationCommands, DebriefCommand, DebriefPaths, Diagnostics,
    HookCommandRunner, HostSource, LiveMcpInstallRunner, McpServer, ModelInstaller, ModelManifest,
    ProcessLaunchctlRunner, RuntimeInstaller, RuntimeInstallerError, ServiceStartResult, UnixSocketClient,
    UreqModelDownloader,
};
use std::collections::HashSet;
use std::io::Write;
use std::path::PathBuf;

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
        DebriefCommand::Daemon => {
            eprintln!("debrief daemon: TTS 추론 엔진이 아직 포팅되지 않았습니다 (별도 계획 필요).");
            std::process::exit(1);
        }
        other => std::process::exit(run_command(other, &home)),
    }
}

fn dirs_home() -> PathBuf {
    std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("/"))
}

fn selected_hosts(codex: bool, claude: bool, grok: bool) -> HashSet<HostSource> {
    if !codex && !claude && !grok {
        return [HostSource::Codex, HostSource::Claude, HostSource::Grok].into_iter().collect();
    }
    let mut hosts = HashSet::new();
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
        DebriefCommand::Install { codex, claude, grok, repair } => {
            let paths = DebriefPaths::for_home(home);
            let hosts = selected_hosts(codex, claude, grok);
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
                    0
                }
                Err(error) => {
                    let detail = format!("{error:?}");
                    let _ = Diagnostics::new(home).record_error("app", "command_failed", &detail);
                    eprintln!("error: {detail}");
                    1
                }
            }
        }
        DebriefCommand::Uninstall { codex, claude, grok } => {
            let hosts = selected_hosts(codex, claude, grok);
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
                    eprintln!("error: {detail}");
                    1
                }
            }
        }
        DebriefCommand::Start => run_start(home),
        DebriefCommand::Stop => run_stop(home),
        DebriefCommand::Status => {
            println!("{}", Diagnostics::new(home).status_text());
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
        DebriefCommand::Hook { source } => {
            let Some(host) = (match source.as_str() {
                "codex" => Some(HostSource::Codex),
                "claude" => Some(HostSource::Claude),
                _ => None,
            }) else {
                eprintln!("error: --source must be codex or claude");
                return 64;
            };
            let mut input = Vec::new();
            if std::io::Read::read_to_end(&mut std::io::stdin(), &mut input).is_err() {
                return 1;
            }
            let output = HookCommandRunner::run(&input, host, home);
            let _ = std::io::stdout().write_all(&output);
            0
        }
        DebriefCommand::Mcp => {
            let paths = DebriefPaths::for_home(home);
            let sink = UnixSocketClient::new(paths.socket_url);
            let install_runner = LiveMcpInstallRunner::new(home.to_path_buf(), current_executable_url());
            let server = McpServer::new(home.to_path_buf(), sink, install_runner);
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
            eprintln!("{}", CliMessages::start_failed(&format!("{error:?}")));
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
            eprintln!("{}", CliMessages::stop_failed(&format!("{error:?}")));
            1
        }
    }
}
