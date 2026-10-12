// Renders the app icon (1024×1024 PNG) from CowArt.
// Usage: swiftc -o make-icon scripts/icon/main.swift Sources/Kuhtake/CowArt.swift && ./make-icon out.png [menubar-preview.png]
import AppKit

func png(_ size: NSSize, _ draw: @escaping (CGRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let icon = png(NSSize(width: 1024, height: 1024)) { _ in
    // Squircle with a soft meadow gradient.
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor.white.setFill(); bg.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(calibratedRed: 0.62, green: 0.86, blue: 0.98, alpha: 1),
                        NSColor(calibratedRed: 0.80, green: 0.94, blue: 0.99, alpha: 1)])!.draw(in: bg, angle: 90)
    // Grass hill.
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    let hill = NSBezierPath()
    hill.move(to: CGPoint(x: 100, y: 330))
    hill.curve(to: CGPoint(x: 924, y: 300), controlPoint1: CGPoint(x: 380, y: 420), controlPoint2: CGPoint(x: 640, y: 380))
    hill.line(to: CGPoint(x: 924, y: 100)); hill.line(to: CGPoint(x: 100, y: 100)); hill.close()
    NSColor(calibratedRed: 0.45, green: 0.78, blue: 0.40, alpha: 1).setFill(); hill.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Cow head.
    CowArt.drawIllustration(in: CGRect(x: 172, y: 150, width: 680, height: 680))

    // REC badge.
    let c = CGPoint(x: 800, y: 240), r: CGFloat = 80
    NSColor.white.setFill()
    NSBezierPath(ovalIn: CGRect(x: c.x - r - 18, y: c.y - r - 18, width: (r + 18) * 2, height: (r + 18) * 2)).fill()
    NSColor(calibratedRed: 0.93, green: 0.16, blue: 0.18, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
}
try! icon.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

if CommandLine.arguments.count > 2 {
    // Menu bar preview: idle + recording at 8× on light and dark strip.
    let preview = png(NSSize(width: 21 * 8 * 2 + 60, height: 18 * 8 * 2 + 60)) { rect in
        for (row, bgColor) in [NSColor(white: 0.92, alpha: 1), NSColor(white: 0.15, alpha: 1)].enumerated() {
            bgColor.setFill()
            NSBezierPath(rect: CGRect(x: 0, y: CGFloat(row) * rect.height / 2, width: rect.width, height: rect.height / 2)).fill()
            for (col, rec) in [false, true].enumerated() {
                let img = CowArt.menuBarImage(recording: rec)
                let target = CGRect(x: 20 + CGFloat(col) * (21 * 8 + 20), y: CGFloat(row) * rect.height / 2 + 15, width: 21 * 8, height: 18 * 8)
                if rec {
                    img.draw(in: target)
                } else {
                    let tinted = NSImage(size: img.size, flipped: false) { r in
                        img.draw(in: r)
                        (row == 0 ? NSColor.black : NSColor.white).set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: target)
                }
            }
        }
    }
    try! preview.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
