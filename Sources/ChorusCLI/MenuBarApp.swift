// 메뉴바 상주 UI 진입점 (NSStatusItem + NSMenu, LSUIElement)
import AppKit
import ChorusCore
import Darwin
import Foundation

/// AppKit-only menubar host.
///
/// **Launch order (critical):** create `NSApplication` + status item first, then start
/// TTS in a background task. Awaiting model load before `app.run()` leaves no visible
/// icon and conflicts with async Swift main for Finder-launched apps.
enum MenuBarApp {
    /// Strong retain for process lifetime (`NSApplication.delegate` is weak).
    @MainActor private static var retainedHost: MenuBarHost?

    /// Shows the status item immediately, starts TTS in the background, then blocks on AppKit.
    /// Must run on the main actor (`await MenuBarApp.runBlocking` from async main).
    @MainActor
    static func runBlocking(home: URL) {
        // Second Finder click while LaunchAgent already owns the resident: exit quietly.
        // (Cannot attach to another process's NSStatusItem.)
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

        // Start TTS after the status item exists (SF Symbol is already visible).
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
            // Guaranteed-visible template glyph first; custom silhouette replaces it if load works.
            button.image = Self.menuBarSymbol(named: "waveform")
        }
        item.isVisible = true
        rebuildMenu()
        applyStatusIcon()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Re-assert visibility once the app is fully in the GUI session.
        item.isVisible = true
        applyStatusIcon()
        Task { await controller.refresh() }
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

    /// Prefers custom silhouette template; always falls back to SF Symbol.
    private func applyStatusIcon() {
        let status = controller.status
        if let custom = Self.menuBarCustomImage() {
            item.button?.image = custom
            item.button?.alphaValue = (status.muted || !status.serviceRunning) ? 0.45 : 1.0
        } else {
            let symbolName: String
            if status.muted {
                symbolName = "speaker.slash.fill"
            } else if status.serviceRunning {
                symbolName = "speaker.wave.2.fill"
            } else {
                symbolName = "waveform"
            }
            item.button?.image = Self.menuBarSymbol(named: symbolName)
            item.button?.alphaValue = 1.0
        }
        item.button?.appearsDisabled = false
        item.isVisible = true
    }

    private static func menuBarCustomImage() -> NSImage? {
        for url in menuBarIconCandidateURLs() {
            guard FileManager.default.fileExists(atPath: url.path),
                  let source = NSImage(contentsOf: url),
                  let prepared = preparedMenuBarImage(source) else { continue }
            return prepared
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
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let fromExecutable = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

    private static func preparedMenuBarImage(_ source: NSImage) -> NSImage? {
        let side: CGFloat = 18
        let pixel = Int(side * 2)
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

        convertToTemplateSilhouette(bitmap)

        // If conversion wiped everything, reject so SF Symbol is used.
        if silhouetteCoverage(bitmap) < 0.02 {
            return nil
        }

        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(bitmap)
        image.isTemplate = true
        return image
    }

    private static func silhouetteCoverage(_ bitmap: NSBitmapImageRep) -> Double {
        guard let data = bitmap.bitmapData else { return 0 }
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let spp = bitmap.samplesPerPixel
        let rowBytes = bitmap.bytesPerRow
        guard spp >= 4, width > 0, height > 0 else { return 0 }
        var solid = 0
        for y in 0..<height {
            let row = data.advanced(by: y * rowBytes)
            for x in 0..<width {
                if row.advanced(by: x * spp)[3] > 32 {
                    solid += 1
                }
            }
        }
        return Double(solid) / Double(width * height)
    }

    private static func convertToTemplateSilhouette(_ bitmap: NSBitmapImageRep) {
        guard let data = bitmap.bitmapData else { return }
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        let spp = bitmap.samplesPerPixel
        let rowBytes = bitmap.bytesPerRow
        guard spp >= 4 else { return }

        for y in 0..<height {
            let row = data.advanced(by: y * rowBytes)
            for x in 0..<width {
                let p = row.advanced(by: x * spp)
                let r = Int(p[0])
                let g = Int(p[1])
                let b = Int(p[2])
                let a = Int(p[3])
                let darkness = max(0, 255 - (r + g + b) / 3)
                // Colorful icons: also treat saturation as signal (not just darkness).
                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                let saturation = maxC - minC
                let strength = max(darkness, saturation)
                let coverage = min(255, (strength * a) / 255)
                let alpha: UInt8
                if coverage < 12 {
                    alpha = 0
                } else if coverage > 160 {
                    alpha = 255
                } else {
                    alpha = UInt8(coverage)
                }
                p[0] = 0
                p[1] = 0
                p[2] = 0
                p[3] = alpha
            }
        }
    }

    private static func menuBarSymbol(named name: String) -> NSImage? {
        let candidates = [name, "waveform", "speaker.wave.2"]
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        for candidate in candidates {
            guard let base = NSImage(systemSymbolName: candidate, accessibilityDescription: "Chorus")
            else { continue }
            let image = base.withSymbolConfiguration(configuration) ?? base
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
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
        item.isVisible = false
        Task { @MainActor in
            await controller.quit()
            Foundation.exit(0)
        }
    }
}
