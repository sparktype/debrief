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
    /// Fixed width so the item stays reserved even while the image loads.
    private let item = NSStatusBar.system.statusItem(withLength: 22)
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
            button.imageHugsTitle = false
            button.toolTip = "Chorus"
        }
        item.isVisible = true
        rebuildMenu()
        // Apply icon again after the status item is attached to the system bar.
        applyStatusIcon()
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

    /// Prefers the installed app `MenuBarIcon` PNG, then SF Symbol fallback.
    private func applyStatusIcon() {
        let status = controller.status
        if let custom = Self.menuBarCustomImage() {
            item.button?.image = custom
            // Opacity encodes state; avoid appearsDisabled (can vanish on some bar styles).
            item.button?.alphaValue = (status.muted || !status.serviceRunning) ? 0.45 : 1.0
            item.button?.appearsDisabled = false
            return
        }

        let symbolName: String
        if status.muted {
            symbolName = "speaker.slash.fill"
        } else if status.serviceRunning {
            symbolName = "speaker.wave.2.fill"
        } else {
            symbolName = "speaker.wave.2"
        }
        item.button?.image = Self.menuBarSymbol(named: symbolName)
        item.button?.alphaValue = 1.0
        item.button?.appearsDisabled = false
    }

    /// Loads `Contents/Resources/MenuBarIcon.png` (or AppIcon) next to the running binary.
    private static func menuBarCustomImage() -> NSImage? {
        for url in menuBarIconCandidateURLs() {
            guard FileManager.default.fileExists(atPath: url.path),
                  let source = NSImage(contentsOf: url) else { continue }
            if let prepared = preparedMenuBarImage(source) {
                return prepared
            }
        }
        return nil
    }

    private static func menuBarIconCandidateURLs() -> [URL] {
        let resources = resourcesDirectory()
        return [
            resources.appending(path: "\(AppBundleInstaller.menuBarIconFileName)@2x.png"),
            resources.appending(path: "\(AppBundleInstaller.menuBarIconFileName).png"),
            resources.appending(path: "\(AppBundleInstaller.iconFileName).icns"),
        ]
    }

    private static func resourcesDirectory() -> URL {
        // Prefer path relative to the running binary (reliable under launchd).
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let fromExecutable = executable
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .appending(path: "Resources", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: fromExecutable.path) {
            return fromExecutable
        }
        if let resourceURL = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resourceURL.path) {
            return resourceURL
        }
        return fromExecutable
    }

    /// Scales into an 18pt menu-bar image. Near-white backgrounds become transparent
    /// so light macOS menu bars do not hide a pale icon.
    private static func preparedMenuBarImage(_ source: NSImage) -> NSImage? {
        let side: CGFloat = 18
        let pixel = Int(side * 2) // draw at 2x for Retina
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixel,
            pixelsHigh: pixel,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        bitmap.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            let rect = NSRect(x: 0, y: 0, width: side, height: side)
            NSColor.clear.setFill()
            rect.fill()
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        NSGraphicsContext.restoreGraphicsState()

        punchNearWhiteToTransparent(bitmap)

        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(bitmap)
        image.isTemplate = false
        return image
    }

    /// Makes near-white / very light pixels transparent (common app-icon backgrounds).
    private static func punchNearWhiteToTransparent(_ bitmap: NSBitmapImageRep) {
        guard let data = bitmap.bitmapData else { return }
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let spp = bitmap.samplesPerPixel
        let rowBytes = bitmap.bytesPerRow
        guard spp >= 3 else { return }

        for y in 0..<height {
            let row = data.advanced(by: y * rowBytes)
            for x in 0..<width {
                let p = row.advanced(by: x * spp)
                let r = p[0]
                let g = p[1]
                let b = p[2]
                // Soft-key light backgrounds typical of exported app icons.
                if r > 230, g > 230, b > 230 {
                    if spp >= 4 {
                        p[3] = 0
                    }
                } else if r > 200, g > 200, b > 200, spp >= 4 {
                    let avg = Int(r) + Int(g) + Int(b)
                    // Partial fade for near-white fringes.
                    let t = UInt8(max(0, min(255, (765 - avg) * 2)))
                    p[3] = min(p[3], t)
                }
            }
        }
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
