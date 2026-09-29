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
