// 메뉴바 상주 UI 진입점 (NSStatusItem + NSMenu, LSUIElement)
import AppKit
import ChorusCore
import Darwin
import Foundation

/// AppKit-only menubar host.
///
/// Must run on the **real main OS thread** (`Thread.isMainThread`), not only
/// Swift `@MainActor` — CLI async main often starts off the main thread, and
/// AppKit status items created there never appear.
@MainActor
enum MenuBarApp {
    private static var retainedHost: MenuBarHost?

    /// Call on MainActor (process main thread). Blocks in `NSApplication.run()`.
    static func runBlocking(home: URL) {
        if ResidentService.isForeignHostRunning(home: home) {
            Foundation.exit(0)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let service = ResidentService(
            home: home,
            backendFactory: { try SupertonicEngine(modelDirectory: $0) },
            audioFactory: { AudioPlayer() }
        )
        let controller = MenuBarController(home: home, service: service)
        let host = MenuBarHost(controller: controller, service: service)
        retainedHost = host
        app.delegate = host

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let interruption = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        termination.setEventHandler {
            Task { @MainActor in host.requestShutdown() }
        }
        interruption.setEventHandler {
            Task { @MainActor in host.requestShutdown() }
        }
        termination.resume()
        interruption.resume()
        host.retainSignalSources([termination, interruption])

        app.run()
    }
}

@MainActor
final class MenuBarHost: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller: MenuBarController
    private let service: ResidentService
    private var item: NSStatusItem?
    private let menu = NSMenu()
    private var signalSources: [any DispatchSourceProtocol] = []
    private var isShuttingDown = false
    private var didInstallStatusItem = false
    /// Template badge images keyed by voice ID (`F1`, `M3`, …) or transport key (`play`/`stop`/`pause`).
    private var badgeImageCache: [String: NSImage] = [:]

    init(controller: MenuBarController, service: ResidentService) {
        self.controller = controller
        self.service = service
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        controller.onStatusChange = { [weak self] in
            Task { @MainActor in
                self?.rebuildMenu()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItemIfNeeded()
        controller.startVoicePolling()
        Task { @MainActor in
            do {
                try await service.start()
            } catch let error as ResidentServiceError where error == .alreadyRunning {
                Foundation.exit(0)
            } catch {
                controller.noteError(error)
            }
            await controller.refresh()
        }
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        installStatusItemIfNeeded()
        item?.isVisible = true
        applyStatusIcon()
    }

    private func installStatusItemIfNeeded() {
        guard !didInstallStatusItem else {
            item?.isVisible = true
            return
        }
        didInstallStatusItem = true

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.imageHugsTitle = false
            button.toolTip = "Chorus"
            // Icon only — no title text in the menu bar.
            button.title = ""
        } else {
            NSLog("Chorus: NSStatusItem.button is nil")
        }

        item = statusItem
        rebuildMenu()
        applyStatusIcon()
        NSLog(
            "Chorus: status item installed visible=%d button=%d mainThread=%d",
            statusItem.isVisible ? 1 : 0,
            statusItem.button != nil ? 1 : 0,
            Thread.isMainThread ? 1 : 0
        )
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

    func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in
            await controller.refresh()
        }
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
                title: MenuBarMenuTitles.error(error),
                action: nil,
                keyEquivalent: ""
            )
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        // MCP agent wiring submenu
        let mcpMenu = NSMenu()
        let mcpLines = controller.status.mcpLines
        if mcpLines.isEmpty {
            let placeholder = NSMenuItem(title: "⚪ 상태 확인 중…", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            mcpMenu.addItem(placeholder)
        } else {
            for line in mcpLines {
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                mcpMenu.addItem(item)
            }
        }
        mcpMenu.addItem(.separator())
        let repairItem = NSMenuItem(
            title: MenuBarMenuTitles.repairMcp,
            action: #selector(repairMcpHosts),
            keyEquivalent: ""
        )
        repairItem.target = self
        repairItem.isEnabled = controller.status.hasMcpProblems
        mcpMenu.addItem(repairItem)
        let mcpRoot = NSMenuItem(
            title: MenuBarMenuTitles.mcpRoot(hasProblems: controller.status.hasMcpProblems),
            action: nil,
            keyEquivalent: ""
        )
        mcpRoot.submenu = mcpMenu
        mcpRoot.isEnabled = true
        menu.addItem(mcpRoot)

        let doctorMenu = NSMenu()
        let problems = controller.status.doctorLines
        if problems.isEmpty {
            let okItem = NSMenuItem(title: MenuBarMenuTitles.doctorOK, action: nil, keyEquivalent: "")
            okItem.isEnabled = false
            doctorMenu.addItem(okItem)
        } else {
            for line in problems {
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                doctorMenu.addItem(item)
            }
        }
        doctorMenu.addItem(.separator())
        let copyItem = NSMenuItem(
            title: MenuBarMenuTitles.copyDoctor,
            action: #selector(copyDoctorReport),
            keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.isEnabled = true
        doctorMenu.addItem(copyItem)
        let doctorRoot = NSMenuItem(
            title: MenuBarMenuTitles.doctorRoot(hasProblems: controller.status.hasDoctorProblems),
            action: nil,
            keyEquivalent: ""
        )
        doctorRoot.submenu = doctorMenu
        doctorRoot.isEnabled = true
        menu.addItem(doctorRoot)

        menu.addItem(.separator())

        let muteItem = NSMenuItem(
            title: MenuBarMenuTitles.mute(isMuted: controller.status.muted),
            action: #selector(toggleMute),
            keyEquivalent: ""
        )
        muteItem.target = self
        muteItem.isEnabled = true
        menu.addItem(muteItem)

        let companionItem = NSMenuItem(
            title: MenuBarMenuTitles.companion(enabled: controller.status.companionEnabled),
            action: #selector(toggleCompanion),
            keyEquivalent: ""
        )
        companionItem.target = self
        companionItem.state = controller.status.companionEnabled ? .on : .off
        companionItem.isEnabled = true
        menu.addItem(companionItem)

        let modeMenu = NSMenu()
        for mode in ChorusMode.allCases {
            let modeItem = NSMenuItem(
                title: mode.menuTitle,
                action: #selector(selectMode(_:)),
                keyEquivalent: ""
            )
            modeItem.target = self
            modeItem.representedObject = mode.rawValue
            modeItem.state = controller.status.mode == mode ? .on : .off
            modeItem.isEnabled = true
            modeMenu.addItem(modeItem)
        }
        let modeRoot = NSMenuItem(title: MenuBarMenuTitles.modeRoot, action: nil, keyEquivalent: "")
        modeRoot.submenu = modeMenu
        modeRoot.isEnabled = true
        menu.addItem(modeRoot)

        menu.addItem(.separator())

        if controller.status.serviceRunning {
            let stopItem = NSMenuItem(
                title: MenuBarMenuTitles.serviceStop,
                action: #selector(stopService),
                keyEquivalent: ""
            )
            stopItem.target = self
            stopItem.isEnabled = true
            menu.addItem(stopItem)
        } else {
            let startItem = NSMenuItem(
                title: MenuBarMenuTitles.serviceStart,
                action: #selector(startService),
                keyEquivalent: ""
            )
            startItem.target = self
            startItem.isEnabled = true
            menu.addItem(startItem)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: MenuBarMenuTitles.quit,
            action: #selector(quitChorus),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        applyStatusIcon()
    }

    private func applyStatusIcon() {
        guard let button = item?.button else { return }
        let status = controller.status
        button.title = ""
        button.imagePosition = .imageOnly
        button.alphaValue = 1.0
        button.appearsDisabled = false

        if let voice = status.activeVoice, !voice.isEmpty {
            button.image = MenuBarBadgeDrawing.makeBadgeImage(
                cacheKey: "voice:\(voice)",
                cache: &badgeImageCache
            ) { bounds in
                MenuBarBadgeDrawing.drawBorder(in: bounds)
                MenuBarBadgeDrawing.drawLabel(voice, in: bounds)
            }
        } else {
            let transport: (key: String, symbol: String)
            if status.muted {
                transport = ("pause", "pause.fill")
            } else if status.serviceRunning {
                transport = ("play", "play.fill")
            } else {
                transport = ("stop", "stop.fill")
            }
            button.image = MenuBarBadgeDrawing.makeBadgeImage(
                cacheKey: "transport:\(transport.key)",
                cache: &badgeImageCache
            ) { bounds in
                MenuBarBadgeDrawing.drawBorder(in: bounds)
                MenuBarBadgeDrawing.drawSymbol(named: transport.symbol, in: bounds)
            }
        }
        item?.isVisible = true
    }

    @objc private func toggleMute() {
        Task { @MainActor in await controller.toggleMute() }
    }

    @objc private func toggleCompanion() {
        Task { @MainActor in await controller.toggleCompanion() }
    }

    @objc private func repairMcpHosts() {
        Task { @MainActor in await controller.repairProblemMcpHosts() }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ChorusMode(rawValue: raw) else { return }
        Task { @MainActor in await controller.setMode(mode) }
    }

    @objc private func startService() {
        Task { @MainActor in await controller.start() }
    }

    @objc private func stopService() {
        Task { @MainActor in await controller.stop() }
    }

    @objc private func copyDoctorReport() {
        let text = controller.doctorReportText()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func quitChorus() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        item?.isVisible = false
        controller.stopVoicePolling()
        Task { @MainActor in
            await controller.quit()
            Foundation.exit(0)
        }
    }
}

private extension ChorusMode {
    /// Menu label with short Korean description of the mode effect.
    var menuTitle: String {
        switch self {
        case .normal: return "normal — 기본"
        case .focus: return "focus — 서브에이전트 억제"
        case .quiet: return "quiet — 볼륨 제한 · 서브에이전트 억제"
        case .verbose: return "verbose — 서브에이전트 포함"
        case .night: return "night — 낮은 볼륨 · 서브에이전트 억제"
        }
    }
}
