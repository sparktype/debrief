import DebriefCore
import Darwin
import Foundation

/// Synchronous `@main` so `debrief daemon` parks on the process main thread.
@main
enum DebriefCLIMain {
    static func main() {
        let command: DebriefCommand
        do {
            command = try DebriefCommand.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n\n\(DebriefCommand.usageText)\n".utf8))
            exit(64)
        }

        let home = ProcessInfo.processInfo.environment["DEBRIEF_HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser

        switch command {
        case .daemon:
            DaemonProcess.run(home: home)
        default:
            let code = CommandRunner.run(command, home: home)
            exit(code)
        }
    }
}

/// Headless resident. Signals stop the service, remove the socket and pid, and exit 0.
private enum DaemonProcess {
    final class State: @unchecked Sendable {
        enum Phase {
            case starting
            case serving
            case parked
            case duplicate
            case failed(any Error)
        }

        var phase: Phase = .starting
    }

    static func run(home: URL) -> Never {
        if ResidentService.isForeignHostRunning(home: home) {
            print(CliMessages.alreadyRunning)
            exit(0)
        }

        let service = ResidentService(
            home: home,
            backendFactory: { try SupertonicEngine(modelDirectory: $0) },
            audioFactory: { AudioPlayer() }
        )
        let state = State()
        let task = Task {
            do {
                try await service.start()
                state.phase = .serving
            } catch ResidentServiceError.alreadyRunning {
                state.phase = .duplicate
            } catch ResidentServiceError.modelUnavailable {
                do {
                    try await service.parkWithoutSocket(message: "모델을 사용할 수 없습니다.")
                    state.phase = .parked
                } catch ResidentServiceError.alreadyRunning {
                    state.phase = .duplicate
                } catch {
                    state.phase = .failed(error)
                }
            } catch {
                state.phase = .failed(error)
            }
            CFRunLoopStop(CFRunLoopGetMain())
        }

        while case .starting = state.phase {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        switch state.phase {
        case .duplicate:
            print(CliMessages.alreadyRunning)
            exit(0)
        case let .failed(error):
            let message = String(describing: error)
            try? Diagnostics(home: home).recordError(component: "daemon", code: "start_failed", message: message)
            FileHandle.standardError.write(Data("error: \(message)\n".utf8))
            exit(1)
        case .starting, .serving, .parked:
            break
        }

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        let finish = {
            termination.cancel()
            interruption.cancel()
            Task {
                await service.stop()
                CFRunLoopStop(CFRunLoopGetMain())
            }
        }
        termination.setEventHandler(handler: finish)
        interruption.setEventHandler(handler: finish)
        termination.resume()
        interruption.resume()
        withExtendedLifetime((termination, interruption, task, service)) {
            RunLoop.main.run()
        }
        exit(0)
    }
}

/// Runs async commands while pumping the main run loop.
private enum CommandRunner {
    final class State: @unchecked Sendable {
        var code: Int32 = 0
        var finished = false
    }

    static func run(_ command: DebriefCommand, home: URL) -> Int32 {
        let state = State()
        let cmd = command
        let homeURL = home
        Task {
            do {
                state.code = try await execute(cmd, home: homeURL)
                if case .install = cmd, state.code == 0 {
                    try? Diagnostics(home: homeURL).clearCurrentError()
                }
            } catch is SilentCommandFailure {
                state.code = 1
            } catch {
                let detail = String(describing: error)
                try? Diagnostics(home: homeURL).recordError(
                    component: "app",
                    code: "command_failed",
                    message: detail
                )
                FileHandle.standardError.write(Data("error: \(detail)\n".utf8))
                state.code = 1
            }
            state.finished = true
            CFRunLoopStop(CFRunLoopGetMain())
        }
        while !state.finished {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        return state.code
    }

    private static func execute(_ command: DebriefCommand, home: URL) async throws -> Int32 {
        switch command {
        case .help:
            print(DebriefCommand.usageText)
        case let .install(codex, claude, grok, repair):
            let paths = DebriefPaths.forHome(home)
            let hosts = selectedHosts(codex: codex, claude: claude, grok: grok)
            let sourceExecutable = currentExecutableURL()
            let runtime = makeRuntime(home: home, sourceExecutable: sourceExecutable)
            let result = try await runtime.install(hosts: hosts, repair: repair)
            print("installed: \(hosts.map(\.rawValue).sorted().joined(separator: ","))")
            print("binary: \(paths.executableURL.path)")
            if result.codexReviewRequired {
                print("Codex에서 /hooks를 열어 debrief hook을 검토하고 신뢰하세요.")
            }
            printPreservedFiles(result.preservedModifiedFiles)
        case let .uninstall(codex, claude, grok):
            let hosts = selectedHosts(codex: codex, claude: claude, grok: grok)
            let sourceExecutable = currentExecutableURL()
            let runtime = makeRuntime(home: home, sourceExecutable: sourceExecutable)
            let result = try await runtime.uninstall(hosts: hosts)
            print("uninstalled: \(hosts.map(\.rawValue).sorted().joined(separator: ","))")
            printPreservedFiles(result.preservedModifiedFiles)
        case .start:
            try await runStart(home: home)
        case .stop:
            try await runStop(home: home)
        case .status:
            print(Diagnostics(home: home).statusText())
        case .doctor:
            let diagnostics = Diagnostics(home: home)
            print(diagnostics.doctorReportText())
            if diagnostics.doctor().contains(where: { !$0.ok }) {
                return 1
            }
        case let .mute(action):
            try printConfiguration {
                let updated = try ConfigurationCommands.applyMute(action, home: home)
                print(updated.muted ? CliMessages.muted : CliMessages.unmuted)
            }
        case let .mode(action):
            try printConfiguration {
                let updated = try ConfigurationCommands.applyMode(action, home: home)
                if action == nil {
                    print(CliMessages.currentMode(updated.mode.rawValue))
                } else {
                    print(CliMessages.modeSet(updated.mode.rawValue))
                }
            }
        case let .companion(action):
            try printConfiguration {
                let updated = try ConfigurationCommands.applyCompanion(action, home: home)
                print(updated.companionEnabled ? CliMessages.companionOn : CliMessages.companionOff)
            }
        case let .hook(sourceValue):
            guard let source = HostSource(rawValue: sourceValue), source != .grok else {
                throw CommandError.usage("--source must be codex or claude")
            }
            let input = FileHandle.standardInput.readDataToEndOfFile()
            let output = await HookCommandRunner.run(input: input, source: source, home: home)
            FileHandle.standardOutput.write(output)
        case .mcp:
            let paths = DebriefPaths.forHome(home)
            let sink = UnixSocketClient(socketURL: paths.socketURL)
            await McpServer(home: home, sink: sink).run()
        case .daemon:
            break
        }
        return 0
    }

    private static func runStart(home: URL) async throws {
        let sourceExecutable = currentExecutableURL()
        do {
            switch try await makeRuntime(home: home, sourceExecutable: sourceExecutable).start() {
            case .alreadyRunning:
                print(CliMessages.alreadyRunning)
            case .started:
                print(CliMessages.started)
            }
        } catch RuntimeInstallerError.launchAgentMissing {
            writeStderr(CliMessages.launchAgentMissing)
            throw SilentCommandFailure()
        } catch {
            writeStderr(CliMessages.startFailed(String(describing: error)))
            throw SilentCommandFailure()
        }
    }

    private static func runStop(home: URL) async throws {
        let sourceExecutable = currentExecutableURL()
        do {
            try await makeRuntime(home: home, sourceExecutable: sourceExecutable).stop()
            print(CliMessages.stopped)
        } catch {
            writeStderr(CliMessages.stopFailed(String(describing: error)))
            throw SilentCommandFailure()
        }
    }

    private static func printConfiguration(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            writeStderr(CliMessages.configSaveFailed(String(describing: error)))
            throw SilentCommandFailure()
        }
    }

    private static func makeRuntime(
        home: URL,
        sourceExecutable: URL
    ) -> RuntimeInstaller<ModelInstaller<URLSessionModelDownloader>, ProcessLaunchctlRunner> {
        let paths = DebriefPaths.forHome(home)
        return RuntimeInstaller(
            home: home,
            sourceExecutable: sourceExecutable,
            modelInstaller: ModelInstaller(
                modelsDirectory: paths.modelsDirectory,
                manifest: .supertonic3,
                downloader: URLSessionModelDownloader()
            ),
            launchctl: ProcessLaunchctlRunner()
        )
    }
}

private struct SilentCommandFailure: Error {}

private func selectedHosts(codex: Bool, claude: Bool, grok: Bool) -> Set<HostSource> {
    if !codex, !claude, !grok { return Set(HostSource.allCases) }
    var hosts = Set<HostSource>()
    if codex { hosts.insert(.codex) }
    if claude { hosts.insert(.claude) }
    if grok { hosts.insert(.grok) }
    return hosts
}

private func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

private func printPreservedFiles(_ paths: [String]) {
    for path in paths {
        print("preserved modified file: \(path)")
    }
}
