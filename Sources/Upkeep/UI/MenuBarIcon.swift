import AppKit

/// Composes the menu bar image: the brand glyph with, when updates are available, a small digit
/// set inside the ring of the arrows. One compact template image instead of glyph + text, so the
/// status item stays as narrow as any other icon.
enum MenuBarIcon {
    enum Mode { case idle, updating, problem }

    static func image(mode: Mode, count: Int) -> NSImage {
        let symbol: String
        switch mode {
        case .idle: symbol = "arrow.triangle.2.circlepath"
        case .updating: symbol = "arrow.triangle.2.circlepath.circle"
        case .problem: symbol = "exclamationmark.triangle"
        }
        let showCount = mode == .idle && count > 0
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: showCount ? .medium : .regular)
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
        let size = NSSize(width: ceil(glyph.size.width), height: ceil(glyph.size.height))

        let image = NSImage(size: size, flipped: false) { rect in
            glyph.draw(in: NSRect(x: (rect.width - glyph.size.width) / 2, y: (rect.height - glyph.size.height) / 2,
                                  width: glyph.size.width, height: glyph.size.height))
            guard showCount else { return true }
            let text = count > 9 ? "9+" : "\(count)"
            let font = NSFont.systemFont(ofSize: count > 9 ? 5.5 : 7, weight: .heavy)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let string = NSAttributedString(string: text, attributes: attributes)
            let textSize = string.size()
            // Optical centre of the ring sits a hair above geometric centre for this glyph.
            let origin = NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2 + 0.5)
            string.draw(at: origin)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = showCount ? "Upkeep: \(count) updates available" : "Upkeep"
        return image
    }

    /// Writes the icon at 4x on a light background for eyeballing (`--icon out.png`).
    static func writePreview(to path: String) {
        let modes: [(Mode, Int)] = [(.idle, 0), (.idle, 2), (.idle, 12), (.updating, 0), (.problem, 0)]
        let scale: CGFloat = 4
        let cell = NSSize(width: 28, height: 22)
        let canvas = NSImage(size: NSSize(width: cell.width * CGFloat(modes.count) * scale, height: cell.height * scale))
        canvas.lockFocus()
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(origin: .zero, size: canvas.size).fill()
        for (index, (mode, count)) in modes.enumerated() {
            let icon = image(mode: mode, count: count)
            icon.isTemplate = false
            let origin = NSPoint(x: (CGFloat(index) * cell.width + (cell.width - icon.size.width) / 2) * scale,
                                 y: (cell.height - icon.size.height) / 2 * scale)
            icon.draw(in: NSRect(origin: origin, size: NSSize(width: icon.size.width * scale, height: icon.size.height * scale)))
        }
        canvas.unlockFocus()
        if let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
