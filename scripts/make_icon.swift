// Draws the 1024×1024 app icon. Usage: make_icon <output.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon shape: 824pt rounded square centred on a 1024 canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.28, alpha: 1),
                    NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.95, alpha: 1),
                    NSColor(calibratedRed: 0.30, green: 0.85, blue: 1.00, alpha: 1)])!
    .draw(in: shape, angle: 60)

// ring
let ring = NSBezierPath(ovalIn: tile.insetBy(dx: 150, dy: 150))
ring.lineWidth = 34
NSColor.white.withAlphaComponent(0.22).setStroke()
ring.stroke()
let arc = NSBezierPath()
arc.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 262, startAngle: 90, endAngle: -150, clockwise: true)
arc.lineWidth = 34; arc.lineCapStyle = .round
NSColor.white.setStroke()
arc.stroke()

// sparkles glyph
if let base = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) {
    var cfg = NSImage.SymbolConfiguration(pointSize: 250, weight: .semibold)
    if #available(macOS 12.0, *) { cfg = cfg.applying(.init(paletteColors: [.white])) }
    if let glyph = base.withSymbolConfiguration(cfg) {
        let s = glyph.size
        glyph.draw(in: NSRect(x: 512 - s.width / 2, y: 512 - s.height / 2, width: s.width, height: s.height))
    }
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
