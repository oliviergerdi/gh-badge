import AppKit

/// Builds the menu bar image: glyph plus badge count, composited into a single
/// template `NSImage`.
///
/// Compositing into one image is required — an `NSStatusItem` shows a single
/// image, not an arbitrary view — and a template image gets the correct
/// light/dark and "menu bar highlighted" tint for free: macOS tints by alpha
/// channel, so the drawn digits adapt along with the glyph.
///
/// ## The glyph
///
/// The bundled Octicons `mark-github` invertocat (shipped as
/// `Support/Glyph/MenuBarGlyph.png` plus `@2x`) is used when present. If the
/// bundle is missing it, the SF Symbol `arrow.triangle.pull` is used as a
/// fallback — semantically a pull request, and guaranteed present.
@MainActor
enum MenuBarIcon {
    private static var cache: [String: NSImage] = [:]

    static let height: CGFloat = 18
    private static let glyphPointSize: CGFloat = 14
    private static let badgeFontSize: CGFloat = 11
    private static let gap: CGFloat = 3

    static func image(count: Int, isError: Bool) -> NSImage {
        let key = isError ? "error" : "count-\(count)"
        if let cached = cache[key] { return cached }
        let image = render(count: count, isError: isError)
        cache[key] = image
        return image
    }

    private static func render(count: Int, isError: Bool) -> NSImage {
        let glyph = glyphImage(isError: isError)
        let badge: String? = (isError || count <= 0) ? nil : String(count)

        // Monospaced digits so the icon does not jitter as the count changes.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: badgeFontSize, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]

        let glyphSize = glyph.size
        let badgeSize = badge.map { ($0 as NSString).size(withAttributes: attributes) } ?? .zero
        let spacing: CGFloat = badge == nil ? 0 : gap
        let width = max(glyphSize.width + spacing + badgeSize.width, 1)

        // Everything the drawing handler needs is captured as a plain local.
        // The handler may be invoked off the main thread, so it must not read
        // main-actor state such as `MenuBarIcon.height`.
        let canvasHeight = height

        let image = NSImage(
            size: NSSize(width: width, height: canvasHeight),
            flipped: false
        ) { _ in
            let glyphRect = NSRect(
                x: 0,
                y: ((canvasHeight - glyphSize.height) / 2).rounded(),
                width: glyphSize.width,
                height: glyphSize.height
            )
            glyph.draw(in: glyphRect)

            if let badge {
                let origin = NSPoint(
                    x: glyphSize.width + spacing,
                    y: ((canvasHeight - badgeSize.height) / 2).rounded()
                )
                (badge as NSString).draw(at: origin, withAttributes: attributes)
            }
            return true
        }

        // Tells the menu bar to tint by alpha instead of using our black pixels.
        image.isTemplate = true
        return image
    }

    private static func glyphImage(isError: Bool) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: glyphPointSize,
            weight: .regular
        )

        if !isError, let bundled = bundledGlyph() {
            return bundled
        }

        let symbolName = isError ? "exclamationmark.triangle.fill" : "arrow.triangle.pull"
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: symbolName),
           let configured = symbol.withSymbolConfiguration(configuration) {
            return configured
        }

        // Last resort so the menu bar item is never invisible.
        return fallbackDot()
    }

    private static func bundledGlyph() -> NSImage? {
        guard let image = NSImage(named: "MenuBarGlyph") else { return nil }
        let scaled = NSImage(size: NSSize(width: 15, height: 15), flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        scaled.isTemplate = true
        return scaled
    }

    private static func fallbackDot() -> NSImage {
        let size = NSSize(width: 13, height: 13)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
