// 메뉴바 배지·실루엣 아이콘 렌더링 (AppKit)
import AppKit
import ChorusCore
import Foundation

/// Shared drawing helpers for the status-item badge (voice ID / transport).
@MainActor
enum MenuBarBadgeDrawing {
    /// Compact menubar badge — wider than the first narrow pass so voice IDs read clearly.
    static let badgeSize = NSSize(width: 25, height: 16)

    static func drawBorder(in bounds: NSRect) {
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: 3.25, yRadius: 3.25)
        NSColor.black.setStroke()
        path.lineWidth = 1.25
        path.stroke()
    }

    static func drawLabel(_ text: String, in bounds: NSRect) {
        let label = text as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .bold)
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

    static func drawSymbol(named name: String, in bounds: NSRect) {
        let candidates = [name, "play.fill", "waveform"]
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        guard let base = candidates.lazy.compactMap({
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }).first else { return }
        let symbol = base.withSymbolConfiguration(configuration) ?? base
        symbol.isTemplate = true
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

    static func makeBadgeImage(
        cacheKey: String,
        cache: inout [String: NSImage],
        draw: (NSRect) -> Void
    ) -> NSImage {
        if let cached = cache[cacheKey] {
            return cached
        }

        let size = badgeSize
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
        cache[cacheKey] = image
        return image
    }
}

/// Loads and converts the app icon PNG into a template silhouette for the menu bar.
@MainActor
enum MenuBarIconLoader {
    static func customImage() -> NSImage? {
        for url in candidateURLs() {
            guard FileManager.default.fileExists(atPath: url.path),
                  let source = NSImage(contentsOf: url),
                  let prepared = preparedTemplate(source) else { continue }
            return prepared
        }
        return nil
    }

    static func systemSymbol(named name: String) -> NSImage? {
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

    private static func candidateURLs() -> [URL] {
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

    private static func preparedTemplate(_ source: NSImage) -> NSImage? {
        let side: CGFloat = 16
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
}
