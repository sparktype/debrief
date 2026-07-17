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
        status = MenuBarStatus(
            serviceRunning: running,
            muted: snapshot.muted,
            mode: snapshot.mode,
            lastError: status.lastError
        )
        onStatusChange?()
    }

    func start() async {
        do {
            try await service.start()
            status.lastError = nil
        } catch {
            status.lastError = String(describing: error)
        }
        await refresh()
    }

    func stop() async {
        await service.stop()
        status.lastError = nil
        await refresh()
    }

    func toggleMute() async {
        do {
            _ = try ConfigurationCommands.applyMute("toggle", home: home)
            status.lastError = nil
        } catch {
            status.lastError = String(describing: error)
        }
        await refresh()
    }

    func setMode(_ mode: ChorusMode) async {
        do {
            _ = try ConfigurationCommands.applyMode(mode.rawValue, home: home)
            status.lastError = nil
        } catch {
            status.lastError = String(describing: error)
        }
        await refresh()
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
}
