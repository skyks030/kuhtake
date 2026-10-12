// Renders the app icon (1024×1024 PNG). Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Background squircle
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedWhite: 0.20, alpha: 1), NSColor(calibratedWhite: 0.07, alpha: 1)])!
    .draw(in: bg, angle: -90)

// Clapper stripes on top
ctx.saveGState()
bg.addClip()
let stripeH: CGFloat = 150
let top = CGRect(x: rect.minX, y: rect.maxY - stripeH, width: rect.width, height: stripeH)
NSColor.white.setFill()
NSBezierPath(rect: top).fill()
NSColor.black.setFill()
var x = rect.minX - 40
while x < rect.maxX {
    let p = NSBezierPath()
    p.move(to: CGPoint(x: x, y: top.minY))
    p.line(to: CGPoint(x: x + 70, y: top.minY))
    p.line(to: CGPoint(x: x + 140, y: top.maxY))
    p.line(to: CGPoint(x: x + 70, y: top.maxY))
    p.close()
    p.fill()
    x += 140
}
ctx.restoreGState()

// Record dot with ring
let center = CGPoint(x: size / 2, y: (rect.minY + top.minY) / 2)
let ringR: CGFloat = 250, dotR: CGFloat = 175
NSColor.white.setStroke()
let ring = NSBezierPath(ovalIn: CGRect(x: center.x - ringR, y: center.y - ringR, width: ringR * 2, height: ringR * 2))
ring.lineWidth = 34
ring.stroke()
NSColor(calibratedRed: 0.95, green: 0.16, blue: 0.16, alpha: 1).setFill()
NSBezierPath(ovalIn: CGRect(x: center.x - dotR, y: center.y - dotR, width: dotR * 2, height: dotR * 2)).fill()

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
