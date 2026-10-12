import AppKit

/// The Kuhtake cow, drawn in code so it stays crisp at every size.
/// All shapes are defined on a 100 × 100 canvas with the origin bottom-left.
enum CowArt {
    private static let outline = NSColor(calibratedRed: 0.23, green: 0.18, blue: 0.16, alpha: 1)
    private static let fur = NSColor(calibratedRed: 1.00, green: 0.98, blue: 0.95, alpha: 1)
    private static let pink = NSColor(calibratedRed: 0.97, green: 0.71, blue: 0.76, alpha: 1)
    private static let earPink = NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.70, alpha: 1)
    private static let horn = NSColor(calibratedRed: 0.95, green: 0.87, blue: 0.72, alpha: 1)

    // MARK: Shapes

    private static func oval(_ cx: CGFloat, _ cy: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
    }

    private static func rotated(_ path: NSBezierPath, degrees: CGFloat, around c: CGPoint) -> NSBezierPath {
        let t = AffineTransform(translationByX: c.x, byY: c.y)
        var r = AffineTransform(rotationByDegrees: degrees)
        r.append(t)
        var back = AffineTransform(translationByX: -c.x, byY: -c.y)
        back.append(r)
        let p = path.copy() as! NSBezierPath
        p.transform(using: back)
        return p
    }

    private static func horn(left: Bool) -> NSBezierPath {
        let s: CGFloat = left ? 1 : -1
        let x0: CGFloat = 50 - s * 20
        let p = NSBezierPath()
        p.move(to: CGPoint(x: x0 - s * 6, y: 75))
        p.curve(to: CGPoint(x: x0 - s * 12, y: 93), controlPoint1: CGPoint(x: x0 - s * 11, y: 80), controlPoint2: CGPoint(x: x0 - s * 14, y: 87))
        p.curve(to: CGPoint(x: x0 + s * 6, y: 79), controlPoint1: CGPoint(x: x0 - s * 4, y: 92), controlPoint2: CGPoint(x: x0 + s * 2, y: 86))
        p.close()
        return p
    }

    private static func ear(left: Bool, inset: CGFloat = 0) -> NSBezierPath {
        let cx: CGFloat = left ? 17 : 83
        return rotated(oval(cx + (left ? inset : -inset), 63, 28 - inset * 2.4, 15 - inset * 2), degrees: left ? -22 : 22,
                       around: CGPoint(x: cx, y: 63))
    }

    private static var head: NSBezierPath {
        NSBezierPath(roundedRect: CGRect(x: 21, y: 30, width: 58, height: 52), xRadius: 27, yRadius: 25)
    }

    private static var muzzle: NSBezierPath { oval(50, 32, 54, 31) }

    // MARK: Full-color illustration

    /// Draws the cute cow head into `rect` of the current graphics context.
    static func drawIllustration(in rect: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / 100, y: rect.height / 100)
        defer { ctx.restoreGState() }

        let line: CGFloat = 2.4
        func fillStroke(_ p: NSBezierPath, _ c: NSColor) {
            c.setFill(); p.fill()
            outline.setStroke(); p.lineWidth = line; p.lineJoinStyle = .round; p.stroke()
        }

        fillStroke(horn(left: true), horn)
        fillStroke(horn(left: false), horn)
        fillStroke(ear(left: true), fur)
        fillStroke(ear(left: false), fur)
        earPink.setFill()
        ear(left: true, inset: 4).fill()
        ear(left: false, inset: 4).fill()

        let head = self.head
        fur.setFill(); head.fill()

        // Spots, clipped to the head.
        NSGraphicsContext.saveGraphicsState()
        head.addClip()
        outline.setFill()
        let spot = NSBezierPath()
        spot.move(to: CGPoint(x: 56, y: 84))
        spot.curve(to: CGPoint(x: 82, y: 66), controlPoint1: CGPoint(x: 70, y: 86), controlPoint2: CGPoint(x: 84, y: 78))
        spot.curve(to: CGPoint(x: 66, y: 66), controlPoint1: CGPoint(x: 76, y: 60), controlPoint2: CGPoint(x: 70, y: 70))
        spot.curve(to: CGPoint(x: 56, y: 84), controlPoint1: CGPoint(x: 58, y: 66), controlPoint2: CGPoint(x: 52, y: 76))
        spot.fill()
        oval(27, 52, 10, 13).fill()
        NSGraphicsContext.restoreGraphicsState()

        outline.setStroke(); head.lineWidth = line; head.stroke()

        // Tuft of hair.
        let tuft = NSBezierPath()
        tuft.move(to: CGPoint(x: 42, y: 81))
        tuft.curve(to: CGPoint(x: 50, y: 82), controlPoint1: CGPoint(x: 43, y: 88), controlPoint2: CGPoint(x: 49, y: 88))
        tuft.curve(to: CGPoint(x: 58, y: 81), controlPoint1: CGPoint(x: 51, y: 88), controlPoint2: CGPoint(x: 57, y: 88))
        fillStroke(tuft, fur)

        // Blush.
        pink.withAlphaComponent(0.75).setFill()
        oval(29, 46, 10, 5.5).fill()
        oval(71, 46, 10, 5.5).fill()

        // Eyes with highlight.
        for x in [38.0, 62.0] as [CGFloat] {
            outline.setFill(); oval(x, 56, 9, 10).fill()
            NSColor.white.setFill(); oval(x + 1.6, 58.2, 3.2, 3.2).fill()
        }

        // Muzzle, nostrils, smile.
        fillStroke(muzzle, pink)
        outline.setFill()
        oval(41, 34, 5.5, 7.5).fill()
        oval(59, 34, 5.5, 7.5).fill()
        let smile = NSBezierPath()
        smile.move(to: CGPoint(x: 44, y: 24.5))
        smile.curve(to: CGPoint(x: 56, y: 24.5), controlPoint1: CGPoint(x: 47, y: 21), controlPoint2: CGPoint(x: 53, y: 21))
        smile.lineWidth = line; smile.lineCapStyle = .round
        outline.setStroke(); smile.stroke()
    }

    static func illustration(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            drawIllustration(in: rect)
            return true
        }
    }

    // MARK: Menu bar

    /// Small cow silhouette. Template (adapts to light/dark menu bar) when idle, solid red while recording.
    static func menuBarImage(recording: Bool, dimmed: Bool = false) -> NSImage {
        let size = NSSize(width: 21, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // Fit the 100×100 canvas (content spans roughly x 3…97, y 15…94).
            let s = min(rect.width / 94, rect.height / 80)
            ctx.translateBy(x: (rect.width - 94 * s) / 2 - 3 * s, y: (rect.height - 80 * s) / 2 - 15 * s)
            ctx.scaleBy(x: s, y: s)

            let color: NSColor = recording ? .systemRed : .black
            color.setFill()
            horn(left: true).fill()
            horn(left: false).fill()
            ear(left: true).fill()
            ear(left: false).fill()
            head.fill()
            muzzle.fill()

            // Punch out face details.
            ctx.setBlendMode(.clear)
            oval(37, 58, 11, 12).fill()
            oval(63, 58, 11, 12).fill()
            oval(41, 32, 8, 11).fill()
            oval(59, 32, 8, 11).fill()
            // Gap between head and muzzle: the muzzle outline, upper half only.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: CGRect(x: 0, y: 34, width: 100, height: 30)).addClip()
            let gap = muzzle
            gap.lineWidth = 5
            gap.stroke()
            NSGraphicsContext.restoreGraphicsState()
            ctx.setBlendMode(.normal)
            return true
        }
        image.isTemplate = !recording
        if dimmed && !recording {
            return NSImage(size: size, flipped: false) { rect in
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.4)
                return true
            }.withTemplate()
        }
        return image
    }
}

private extension NSImage {
    func withTemplate() -> NSImage {
        isTemplate = true
        return self
    }
}
