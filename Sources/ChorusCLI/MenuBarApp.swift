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
        do {
            try await service.start()
        } catch {
            controller.noteError(String(describing: error))
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
final class MenuBarHost: NSObject, NSApplicationDelegate {
    private let controller: MenuBarController
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var signalSources: [any DispatchSourceProtocol] = []
    private var isShuttingDown = false

    init(controller: MenuBarController) {
        self.controller = controller
        super.init()
        controller.onStatusChange = { [weak self] in
            self?.rebuildMenu()
        }
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "Chorus"
            )
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

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

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
        // No Quit — full off via uninstall / launchctl (KeepAlive).

        let symbol = controller.status.serviceRunning ? "waveform" : "waveform.slash"
        item.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Chorus"
        )
        item.menu = menu
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
}

