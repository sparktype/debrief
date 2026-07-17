// 메뉴바 상주 UI 진입점 (NSStatusItem + NSMenu, LSUIElement)
import AppKit
import ChorusCore
import Darwin
import Foundation

/// AppKit-only menubar host.
/// Uses `NSStatusItem` + `NSMenu` (not SwiftUI `MenuBarExtra`/`App`) so CLI `main`
/// and the menubar path do not fight over dual entry points.
enum MenuBarApp {
    /// Strong retain for process lifetime (`NSApplication.delegate` is weak).
    @MainActor private static var retainedHost: MenuBarHost?

    @MainActor
    static func run(home: URL) async {
        let service = ResidentService(
            home: home,
            backendFactory: { try SupertonicEngine(modelDirectory: $0) },
            audioFactory: { AudioPlayer() }
        )

        let controller = MenuBarController(home: home, service: service)

        // Auto-start ResidentService on launch (LaunchAgent path).
        // If another healthy resident already owns pid+socket, exit without UI
        // so a second `chorus menubar` does not install another NSStatusItem.
        do {
            try await service.start()
        } catch let error as ResidentServiceError where error == .alreadyRunning {
            Foundation.exit(0)
        } catch {
            // modelUnavailable etc. — keep menu so user can Start retry.
            controller.noteError(error)
        }
        await controller.refresh()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let host = MenuBarHost(controller: controller)
        retainedHost = host
        app.delegate = host

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        termination.setEventHandler { host.requestShutdown() }
        interruption.setEventHandler { host.requestShutdown() }
        termination.resume()
        interruption.resume()
        host.retainSignalSources([termination, interruption])

        app.run()
    }
}

@MainActor
final class MenuBarHost: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller: MenuBarController
    /// Square length keeps a consistent monochrome glyph footprint in the menu bar.
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    /// Stable menu instance — rebuild mutates items in place so open menus stay visible.
    private let menu = NSMenu()
    private var signalSources: [any DispatchSourceProtocol] = []
    private var isShuttingDown = false

    init(controller: MenuBarController) {
        self.controller = controller
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        controller.onStatusChange = { [weak self] in
            self?.rebuildMenu()
        }
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Chorus"
        }
        rebuildMenu()
    }

    func retainSignalSources(_ sources: [any DispatchSourceProtocol]) {
        signalSources.append(contentsOf: sources)
    }

    func requestShutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        Task { @MainActor in
            await controller.shutdownService()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isShuttingDown else { return .terminateNow }
        isShuttingDown = true
        Task { @MainActor in
            await controller.shutdownService()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Refresh status when the menu opens so header/icon track service death and config.
    func menuWillOpen(_ menu: NSMenu) {
        Task { await controller.refresh() }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let header = NSMenuItem(
            title: controller.status.summaryLine,
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)

        if let error = controller.status.lastError {
            let errorItem = NSMenuItem(
                title: "오류: \(error)",
                action: nil,
                keyEquivalent: ""
            )
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        menu.addItem(.separator())

        let muteTitle = controller.status.muted ? "음소거 해제" : "음소거"
        let muteItem = NSMenuItem(
            title: muteTitle,
            action: #selector(toggleMute),
            keyEquivalent: ""
        )
        muteItem.target = self
        muteItem.isEnabled = true
        menu.addItem(muteItem)

        let modeMenu = NSMenu()
        for mode in ChorusMode.allCases {
            let modeItem = NSMenuItem(
                title: mode.rawValue,
                action: #selector(selectMode(_:)),
                keyEquivalent: ""
            )
            modeItem.target = self
            modeItem.representedObject = mode.rawValue
            modeItem.state = controller.status.mode == mode ? .on : .off
            modeItem.isEnabled = true
            modeMenu.addItem(modeItem)
        }
        let modeRoot = NSMenuItem(title: "모드", action: nil, keyEquivalent: "")
        modeRoot.submenu = modeMenu
        modeRoot.isEnabled = true
        menu.addItem(modeRoot)

        menu.addItem(.separator())

        if controller.status.serviceRunning {
            let stopItem = NSMenuItem(
                title: "서비스 중지",
                action: #selector(stopService),
                keyEquivalent: ""
            )
            stopItem.target = self
            stopItem.isEnabled = true
            menu.addItem(stopItem)
        } else {
            let startItem = NSMenuItem(
                title: "서비스 시작",
                action: #selector(startService),
                keyEquivalent: ""
            )
            startItem.target = self
            startItem.isEnabled = true
            menu.addItem(startItem)
        }

        menu.addItem(.separator())

        // Quit boots out LaunchAgent first so KeepAlive does not immediately relaunch.
        let quitItem = NSMenuItem(
            title: "Chorus 종료",
            action: #selector(quitChorus),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        applyStatusIcon()
    }

    /// Menu-bar SF Symbols must be template images at a fixed point size.
    /// Unconfigured symbols often render oversized, multicolored, or clipped.
    private func applyStatusIcon() {
        let status = controller.status
        let symbolName: String
        if status.muted {
            symbolName = "speaker.slash.fill"
        } else if status.serviceRunning {
            symbolName = "speaker.wave.2.fill"
        } else {
            symbolName = "speaker.wave.2"
        }

        item.button?.image = Self.menuBarSymbol(named: symbolName)
        // Keep full opacity — `appearsDisabled` looks washed-out/broken in the menu bar.
        item.button?.appearsDisabled = false
    }

    /// Builds a monochrome template glyph sized for `NSStatusItem`.
    private static func menuBarSymbol(named name: String) -> NSImage? {
        let candidates = [name, "speaker.wave.2", "waveform"]
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        for candidate in candidates {
            guard let base = NSImage(systemSymbolName: candidate, accessibilityDescription: "Chorus")
            else { continue }
            let image = base.withSymbolConfiguration(configuration) ?? base
            image.isTemplate = true
            // Explicit pixel size helps bare executables (no asset catalog) scale cleanly.
            let side: CGFloat = 18
            image.size = NSSize(width: side, height: side)
            return image
        }
        return nil
    }

    @objc private func toggleMute() {
        Task { await controller.toggleMute() }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ChorusMode(rawValue: raw) else { return }
        Task { await controller.setMode(mode) }
    }

    @objc private func startService() {
        Task { await controller.start() }
    }

    @objc private func stopService() {
        Task { await controller.stop() }
    }

    @objc private func quitChorus() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        // Hide status item immediately so the UI feels responsive.
        item.isVisible = false
        Task { @MainActor in
            await controller.quit()
            // Hard exit: NSApp.terminate can stall under launchd agent unload,
            // and we must not block on bootout (self-deadlock with launchd).
            Foundation.exit(0)
        }
    }
}
