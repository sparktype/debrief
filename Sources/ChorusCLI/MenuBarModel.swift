// 메뉴바 액션 컨트롤러 (start/stop/mute/mode/status)
import ChorusCore
import Foundation

/// Drives menu actions against `ResidentService` + config/diagnostics.
@MainActor
final class MenuBarController {
    private(set) var status: MenuBarStatus
    private let home: URL
    /// Retained for process lifetime — menu stop does not release the service.
    private let service: ResidentService
    /// Install/repair runner for MCP host rewiring (injectable in tests).
    private let installRunner: any McpInstallRunning
    var onStatusChange: (() -> Void)?

    /// Serializes start/stop/mute/mode so concurrent menu clicks do not race.
    private var actionTask: Task<Void, Never>?
    /// Polls active voice while the menu bar is up.
    private var voicePollTask: Task<Void, Never>?

    init(
        home: URL,
        service: ResidentService,
        installRunner: (any McpInstallRunning)? = nil
    ) {
        self.home = home
        self.service = service
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        self.installRunner = installRunner
            ?? LiveMcpInstallRunner(home: home, sourceExecutable: source)
        self.status = MenuBarStatus(
            serviceRunning: false,
            muted: false,
            companionEnabled: true,
            mode: .normal,
            activeVoice: nil,
            lastError: nil,
            doctorLines: [],
            mcpLines: [],
            hasMcpProblems: false
        )
    }

    /// Starts a short-interval poll so the status item can show the speaking voice.
    func startVoicePolling() {
        voicePollTask?.cancel()
        voicePollTask = Task { @MainActor in
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func stopVoicePolling() {
        voicePollTask?.cancel()
        voicePollTask = nil
    }

    func refresh() async {
        let diagnostics = Diagnostics(home: home)
        let snapshot = diagnostics.status()
        let running = await service.isRunning
        let voice = await service.activeVoice()
        var lastError: String?
        if let failure = await service.consumeRunFailure() {
            lastError = Self.describe(failure)
        } else if let persisted = diagnostics.currentError()?.message, !persisted.isEmpty {
            // Surface hook delivery / daemon failures recorded outside the UI process.
            lastError = persisted
        }
        let mcp = diagnostics.hostMcpStatuses()
        let next = MenuBarStatus(
            serviceRunning: running,
            muted: snapshot.muted,
            companionEnabled: snapshot.companionEnabled,
            mode: snapshot.mode,
            activeVoice: voice,
            lastError: lastError,
            doctorLines: diagnostics.doctorProblemLines(),
            mcpLines: mcp.map(\.menuLine),
            hasMcpProblems: mcp.contains(where: \.isProblem)
        )
        // Avoid rebuilding the menu on every poll tick when nothing visible changed.
        if next != status {
            status = next
            onStatusChange?()
        }
    }

    /// Re-runs install --repair for hosts whose MCP wiring is broken (not absent/ok).
    func repairProblemMcpHosts() async {
        await enqueue {
            let paths = ChorusPaths.forHome(self.home)
            let problems = HostMcpProbe.problemHosts(
                home: self.home,
                expectedExecutable: paths.executableURL
            )
            guard !problems.isEmpty else {
                await self.refresh()
                return
            }
            do {
                _ = try await self.installRunner.install(hosts: problems, repair: true)
                try? Diagnostics(home: self.home).clearCurrentError()
                self.status.lastError = nil
            } catch {
                let detail = String(describing: error)
                try? Diagnostics(home: self.home).recordError(
                    component: "mcp",
                    code: "menu_repair_failed",
                    message: detail
                )
                self.status.lastError = Self.describe(error)
            }
            await self.refresh()
        }
    }

    func start() async {
        await enqueue {
            do {
                try await self.service.start()
                try? Diagnostics(home: self.home).clearCurrentError()
                self.status.lastError = nil
            } catch {
                self.status.lastError = Self.describe(error)
            }
            await self.refresh()
        }
    }

    func stop() async {
        await enqueue {
            // Keep host pid: menubar process stays alive; only TTS service stops.
            await self.service.stop(removePid: false)
            self.status.lastError = nil
            await self.refresh()
        }
    }

    func toggleMute() async {
        await enqueue {
            do {
                _ = try ConfigurationCommands.applyMute("toggle", home: self.home)
                self.status.lastError = nil
            } catch {
                self.status.lastError = Self.describe(error)
            }
            await self.refresh()
        }
    }

    func setMode(_ mode: ChorusMode) async {
        await enqueue {
            do {
                _ = try ConfigurationCommands.applyMode(mode.rawValue, home: self.home)
                self.status.lastError = nil
            } catch {
                self.status.lastError = Self.describe(error)
            }
            await self.refresh()
        }
    }

    func toggleCompanion() async {
        await enqueue {
            do {
                _ = try ConfigurationCommands.applyCompanion("toggle", home: self.home)
                self.status.lastError = nil
            } catch {
                self.status.lastError = Self.describe(error)
            }
            await self.refresh()
        }
    }

    /// Full teardown on process exit — removes pid so Diagnostics sees host gone.
    func shutdownService() async {
        await service.stop(removePid: true)
    }

    /// Menu Quit: disable LaunchAgent (so KeepAlive will not relaunch), then full stop.
    /// Must **not** await `bootout` from inside this process — launchd waits for our exit.
    /// SIGTERM/system terminate should call `shutdownService()` only — not this.
    func quit(launchctl: any LaunchctlRunning = ProcessLaunchctlRunner()) async {
        await enqueue {
            try? await LaunchAgentControl.disable(launchctl: launchctl)
            await self.service.stop(removePid: true)
            // Best-effort unload after we are disabled; do not wait (avoids self-deadlock).
            LaunchAgentControl.bootoutDetached()
        }
    }

    /// Records a launch-time or external error before the first refresh.
    func noteError(_ message: String) {
        status.lastError = message
        onStatusChange?()
    }

    /// Records a typed error using the Korean short-string map when applicable.
    func noteError(_ error: any Error) {
        noteError(Self.describe(error))
    }

    /// Plain-text doctor report for the pasteboard.
    func doctorReportText() -> String {
        Diagnostics(home: home).doctorReportText()
    }

    // MARK: - Serialization

    /// Chains work onto a single in-flight task so menu actions run serially.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) async {
        let previous = actionTask
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        actionTask = task
        await task.value
    }

    // MARK: - Errors

    static func describe(_ error: any Error) -> String {
        if let serviceError = error as? ResidentServiceError {
            switch serviceError {
            case .alreadyRunning:
                return "이미 실행 중입니다"
            case .modelUnavailable:
                return "모델을 사용할 수 없습니다"
            case .notRunning:
                return "서비스가 실행 중이 아닙니다"
            }
        }
        return error.localizedDescription
    }
}
