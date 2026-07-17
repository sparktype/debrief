// 메뉴바 액션 컨트롤러 (start/stop/mute/mode/status)
import ChorusCore
import Foundation

/// Drives menu actions against `ResidentService` + config/diagnostics.
/// AppKit UI lives in `MenuBarApp`; this type stays free of UI frameworks.
@MainActor
final class MenuBarController {
    private(set) var status: MenuBarStatus
    private let home: URL
    /// Retained for process lifetime — menu stop does not release the service.
    private let service: ResidentService
    var onStatusChange: (() -> Void)?

    /// Serializes start/stop/mute/mode so concurrent menu clicks do not race.
    private var actionTask: Task<Void, Never>?

    init(home: URL, service: ResidentService) {
        self.home = home
        self.service = service
        self.status = MenuBarStatus(
            serviceRunning: false,
            muted: false,
            mode: .normal,
            lastError: nil
        )
    }

    func refresh() async {
        let snapshot = Diagnostics(home: home).status()
        let running = await service.isRunning
        var lastError = status.lastError
        if let failure = await service.consumeRunFailure() {
            lastError = Self.describe(failure)
        }
        status = MenuBarStatus(
            serviceRunning: running,
            muted: snapshot.muted,
            mode: snapshot.mode,
            lastError: lastError
        )
        onStatusChange?()
    }

    func start() async {
        await enqueue {
            do {
                try await self.service.start()
                self.status.lastError = nil
            } catch {
                self.status.lastError = Self.describe(error)
            }
            await self.refresh()
        }
    }

    func stop() async {
        await enqueue {
            await self.service.stop()
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

    /// Stops the in-process service without releasing the retained handle.
    func shutdownService() async {
        await service.stop()
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
