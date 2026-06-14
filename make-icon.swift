import AppKit

// Renders the app icon (terminal + tunnel) as a full macOS .iconset.
// Usage:  swift make-icon.swift [output.iconset]
//
// Pure vector drawing so every size stays crisp. Concept:
//   • rounded "squircle" background with a blue gradient
//   • a terminal window (traffic-light dots) as the body
//   • a glowing green perspective tunnel (concentric rounded rects)
//   • a dashed connection line + arrow heading INTO the tunnel
//   • a small green >_ prompt to anchor the "terminal" read

// MARK: - Helpers

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

func lerpPoint(_ a: NSPoint, _ b: NSPoint, _ t: CGFloat) -> NSPoint {
    NSPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t))
}

func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    let ca = a.usingColorSpace(.deviceRGB) ?? a
    let cb = b.usingColorSpace(.deviceRGB) ?? b
    return NSColor(deviceRed: lerp(ca.redComponent, cb.redComponent, t),
                   green: lerp(ca.greenComponent, cb.greenComponent, t),
                   blue: lerp(ca.blueComponent, cb.blueComponent, t),
                   alpha: lerp(ca.alphaComponent, cb.alphaComponent, t))
}

func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

// Palette
let bgTop   = NSColor(deviceRed: 0.231, green: 0.494, blue: 0.847, alpha: 1) // #3B7ED8
let bgBot   = NSColor(deviceRed: 0.094, green: 0.220, blue: 0.420, alpha: 1) // #18386B
let termFill   = NSColor(deviceRed: 0.063, green: 0.082, blue: 0.118, alpha: 1) // #10151E
let headerFill = NSColor(deviceRed: 0.102, green: 0.129, blue: 0.180, alpha: 1) // #1A212E
let dotRed    = NSColor(deviceRed: 1.00, green: 0.373, blue: 0.341, alpha: 1)
let dotYellow = NSColor(deviceRed: 1.00, green: 0.737, blue: 0.180, alpha: 1)
let dotGreen  = NSColor(deviceRed: 0.157, green: 0.784, blue: 0.251, alpha: 1)
let neon      = NSColor(deviceRed: 0.275, green: 0.945, blue: 0.557, alpha: 1) // #46F18E
let tunnelOuter = NSColor(deviceRed: 0.231, green: 0.910, blue: 0.522, alpha: 1)
let tunnelCore  = NSColor(deviceRed: 0.024, green: 0.067, blue: 0.090, alpha: 1)

// MARK: - Drawing

func drawIcon(_ S: CGFloat) {
    let ctx = NSGraphicsContext.current!
    func P(_ fx: CGFloat, _ fy: CGFloat) -> NSPoint { NSPoint(x: fx * S, y: fy * S) }

    // Background squircle.
    let m = 0.094 * S
    let rectW = S - 2 * m
    let squircle = rrect(m, m, rectW, rectW, 0.2237 * rectW)

    ctx.saveGraphicsState()
    squircle.addClip()
    if let g = NSGradient(starting: bgTop, ending: bgBot) {
        g.draw(in: squircle.bounds, angle: -90)
    }
    // Top gloss.
    if let gloss = NSGradient(starting: NSColor(white: 1, alpha: 0.16),
                              ending: NSColor(white: 1, alpha: 0.0)) {
        gloss.draw(in: NSRect(x: m, y: 0.52 * S, width: rectW, height: 0.48 * S), angle: -90)
    }
    ctx.restoreGraphicsState()

    // Everything else clipped to the squircle so shadows don't leak outside.
    ctx.saveGraphicsState()
    squircle.addClip()

    // Terminal window geometry.
    let tx = 0.205 * S, ty = 0.230 * S, tw = 0.590 * S, th = 0.490 * S, tr = 0.046 * S
    let term = rrect(tx, ty, tw, th, tr)

    // Drop shadow under the terminal.
    ctx.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
    shadow.shadowBlurRadius = 0.030 * S
    shadow.shadowOffset = NSSize(width: 0, height: -0.012 * S)
    shadow.set()
    termFill.setFill()
    term.fill()
    ctx.restoreGraphicsState()

    // Header bar + traffic-light dots (clipped to the terminal for square bottom edge).
    let hh = 0.072 * S
    ctx.saveGraphicsState()
    term.addClip()
    headerFill.setFill()
    NSBezierPath(rect: NSRect(x: tx, y: ty + th - hh, width: tw, height: hh)).fill()
    let dotR = 0.0135 * S
    let dotY = ty + th - hh / 2
    for (i, c) in [dotRed, dotYellow, dotGreen].enumerated() {
        c.setFill()
        let cx = tx + 0.042 * S + CGFloat(i) * 0.040 * S
        NSBezierPath(ovalIn: NSRect(x: cx - dotR, y: dotY - dotR, width: 2 * dotR, height: 2 * dotR)).fill()
    }
    ctx.restoreGraphicsState()

    // Glowing perspective tunnel: concentric rounded rects receding to a vanishing point.
    ctx.saveGraphicsState()
    term.addClip()
    let outerC = P(0.500, 0.398)
    let vanish = P(0.516, 0.430)
    let outerW = 0.404 * S, outerH = 0.250 * S, outerR = 0.050 * S
    let count = 7
    for i in 0..<count {
        let t = CGFloat(i) / CGFloat(count - 1)
        let scale = pow(0.74, CGFloat(i))
        let w = outerW * scale, h = outerH * scale, r = outerR * scale
        let c = lerpPoint(outerC, vanish, t)
        let col = mix(tunnelOuter, tunnelCore, pow(t, 0.85))
        let ring = rrect(c.x - w / 2, c.y - h / 2, w, h, r)
        if i == 0 {
            ctx.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = tunnelOuter.withAlphaComponent(0.65)
            glow.shadowBlurRadius = 0.045 * S
            glow.shadowOffset = .zero
            glow.set()
            col.setFill(); ring.fill()
            ctx.restoreGraphicsState()
        } else {
            col.setFill(); ring.fill()
        }
    }
    ctx.restoreGraphicsState()

    // Dashed connection line + arrowhead heading into the tunnel mouth.
    ctx.saveGraphicsState()
    term.addClip()
    let start = P(0.272, 0.318)
    let end   = P(0.452, 0.384)
    let line = NSBezierPath()
    line.move(to: start); line.line(to: end)
    line.lineWidth = 0.0145 * S
    line.lineCapStyle = .round
    line.setLineDash([0.030 * S, 0.022 * S], count: 2, phase: 0)
    neon.setStroke(); line.stroke()

    let dx = end.x - start.x, dy = end.y - start.y
    let len = max(hypot(dx, dy), 0.0001)
    let ux = dx / len, uy = dy / len
    let ah = 0.052 * S, aw = 0.034 * S
    let base = NSPoint(x: end.x - ux * ah, y: end.y - uy * ah)
    let head = NSBezierPath()
    head.move(to: end)
    head.line(to: NSPoint(x: base.x - uy * aw / 2, y: base.y + ux * aw / 2))
    head.line(to: NSPoint(x: base.x + uy * aw / 2, y: base.y - ux * aw / 2))
    head.close()
    neon.setFill(); head.fill()
    ctx.restoreGraphicsState()

    // >_ prompt near the top-left of the screen.
    let chevron = NSBezierPath()
    chevron.move(to: P(0.248, 0.604))
    chevron.line(to: P(0.282, 0.583))
    chevron.line(to: P(0.248, 0.562))
    chevron.lineWidth = 0.014 * S
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    neon.setStroke(); chevron.stroke()
    neon.setFill()
    rrect(0.296 * S, 0.560 * S, 0.052 * S, 0.011 * S, 0.0055 * S).fill()

    ctx.restoreGraphicsState() // squircle clip

    // Subtle rim stroke on top.
    NSColor(white: 1, alpha: 0.10).setStroke()
    squircle.lineWidth = 0.004 * S
    squircle.stroke()
}

// MARK: - Render each size

func renderPNG(_ size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: size, height: size)
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    drawIcon(CGFloat(size))
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in specs {
    guard let data = renderPNG(px) else {
        FileHandle.standardError.write(Data("✗ failed to render \(name)\n".utf8))
        exit(1)
    }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
    do { try data.write(to: url) }
    catch { FileHandle.standardError.write(Data("✗ failed to write \(url.path): \(error)\n".utf8)); exit(1) }
}

print("✓ wrote \(specs.count) PNGs to \(outDir)")
