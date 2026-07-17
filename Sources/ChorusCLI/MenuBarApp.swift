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
    /// Shared badge frame — same width/height for voice and transport icons.
    private static let badgeSize = NSSize(width: 28, height: 16)

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

    private func applyStatusIcon() {
        guard let button = item?.button else { return }
        let status = controller.status
        button.title = ""
        button.imagePosition = .imageOnly
        button.alphaValue = 1.0
        button.appearsDisabled = false

        if let voice = status.activeVoice, !voice.isEmpty {
            // Speaking: monochrome badge icon for the active voice (F1 / M1 / …).
            button.image = badgeImage(cacheKey: "voice:\(voice)") { bounds in
                Self.drawBadgeBorder(in: bounds)
                Self.drawBadgeLabel(voice, in: bounds)
            }
        } else {
            // Idle: play / stop / pause inside the same bordered badge frame as voice IDs.
            let transport: (key: String, symbol: String)
            if status.muted {
                transport = ("pause", "pause.fill")
            } else if status.serviceRunning {
                transport = ("play", "play.fill")
            } else {
                transport = ("stop", "stop.fill")
            }
            button.image = badgeImage(cacheKey: "transport:\(transport.key)") { bounds in
                Self.drawBadgeBorder(in: bounds)
                Self.drawBadgeSymbol(named: transport.symbol, in: bounds)
            }
        }
        item?.isVisible = true
    }

    /// Shared badge canvas (same size as voice badges) with a cache key.
    private func badgeImage(cacheKey: String, draw: (NSRect) -> Void) -> NSImage {
        if let cached = badgeImageCache[cacheKey] {
            return cached
        }

        let size = Self.badgeSize
        let scale = 2
        let image = NSImage(size: size)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width) * scale,
            pixelsHigh: Int(size.height) * scale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return image
        }
        bitmap.size = size

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            let bounds = NSRect(origin: .zero, size: size)
            NSColor.clear.setFill()
            bounds.fill()
            draw(bounds)
        }
        NSGraphicsContext.restoreGraphicsState()

        image.addRepresentation(bitmap)
        image.isTemplate = true
        badgeImageCache[cacheKey] = image
        return image
    }

    private static func drawBadgeBorder(in bounds: NSRect) {
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: 3.5, yRadius: 3.5)
        NSColor.black.setStroke()
        path.lineWidth = 1.25
        path.stroke()
    }

    private static func drawBadgeLabel(_ text: String, in bounds: NSRect) {
        let label = text as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let textSize = label.size(withAttributes: attributes)
        let textOrigin = NSPoint(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2 - 0.5
        )
        label.draw(at: textOrigin, withAttributes: attributes)
    }

    private static func drawBadgeSymbol(named name: String, in bounds: NSRect) {
        let candidates = [name, "play.fill", "waveform"]
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        guard let base = candidates.lazy.compactMap({
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }).first else { return }
        let symbol = base.withSymbolConfiguration(configuration) ?? base
        symbol.isTemplate = true
        // Fit glyph inside the pill with even padding (same outer frame as F1/M1).
        let maxSide = min(bounds.width, bounds.height) - 5
        let glyphSize = NSSize(width: maxSide, height: maxSide)
        let origin = NSPoint(
            x: (bounds.width - glyphSize.width) / 2,
            y: (bounds.height - glyphSize.height) / 2
        )
        symbol.draw(
            in: NSRect(origin: origin, size: glyphSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
    }

    private func menuBarCustomImage() -> NSImage? {
        for url in menuBarIconCandidateURLs() {
            guard FileManager.default.fileExists(atPath: url.path),
                  let source = NSImage(contentsOf: url),
                  let prepared = preparedMenuBarImage(source) else { continue }
            return prepared
        }
        return nil
    }

    private func menuBarIconCandidateURLs() -> [URL] {
        let resources = resourcesDirectory()
        return [
            resources.appending(path: "\(AppBundleInstaller.menuBarIconFileName)@2x.png"),
            resources.appending(path: "\(AppBundleInstaller.menuBarIconFileName).png"),
            resources.appending(path: "\(AppBundleInstaller.iconFileName).icns"),
        ]
    }

    private func resourcesDirectory() -> URL {
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

    private func preparedMenuBarImage(_ source: NSImage) -> NSImage? {
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
        if silhouetteCoverage(bitmap) < 0.02 {
            return nil
        }

        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(bitmap)
        image.isTemplate = true
        return image
    }

    private func silhouetteCoverage(_ bitmap: NSBitmapImageRep) -> Double {
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

    private func convertToTemplateSilhouette(_ bitmap: NSBitmapImageRep) {
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

    private func menuBarSymbol(named name: String) -> NSImage? {
        let candidates = [name, "waveform", "speaker.wave.2"]
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        for candidate in candidates {
            guard let base = NSImage(systemSymbolName: candidate, accessibilityDescription: "Chorus")
            else { continue }
            let image = base.withSymbolConfiguration(configuration) ?? base
            image.isTemplate = true
            image.size = NSSize(width: 16, height: 16)
            return image
        }
        return nil
    }

    @objc private func toggleMute() {
        Task { @MainActor in await controller.toggleMute() }
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
