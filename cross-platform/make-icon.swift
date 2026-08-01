import AppKit

// Renders the cross-platform "Remote Stuff CP" app icon as a full macOS .iconset.
// Usage:  swift make-icon.swift [output.iconset]
//
// Concept (distinct from the native Swift app's terminal-tunnel icon):
//   • rounded squircle with a teal → violet diagonal gradient
//   • two tilted orbit rings ("cross-platform reach")
//   • multi-coloured glowing device nodes riding the orbits
//   • a central dark terminal chip with a neon >_ prompt

// MARK: - Helpers

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

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
let bgTop    = NSColor(deviceRed: 0.086, green: 0.784, blue: 0.702, alpha: 1) // #16C8B3 teal
let bgMid    = NSColor(deviceRed: 0.161, green: 0.451, blue: 0.827, alpha: 1) // #2973D3 blue
let bgBot    = NSColor(deviceRed: 0.373, green: 0.192, blue: 0.808, alpha: 1) // #5F31CE violet
let chipFill = NSColor(deviceRed: 0.055, green: 0.078, blue: 0.125, alpha: 1) // #0E1420
let neon     = NSColor(deviceRed: 0.275, green: 0.945, blue: 0.557, alpha: 1) // #46F18E green
let nodeCyan = NSColor(deviceRed: 0.290, green: 0.878, blue: 0.965, alpha: 1) // #4AE0F6
let nodeMag  = NSColor(deviceRed: 0.957, green: 0.361, blue: 0.804, alpha: 1) // #F45CCD
let nodeAmber = NSColor(deviceRed: 1.000, green: 0.741, blue: 0.212, alpha: 1) // #FFBD36
let ringHi   = NSColor(white: 1, alpha: 0.36)
let ringLo   = NSColor(white: 1, alpha: 0.22)

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
    if let g = NSGradient(colors: [bgTop, bgMid, bgBot]) {
        g.draw(in: squircle.bounds, angle: -60)
    }
    // Soft radial glow behind the chip.
    if let rg = NSGradient(starting: NSColor(white: 1, alpha: 0.18), ending: NSColor(white: 1, alpha: 0)) {
        rg.draw(fromCenter: P(0.5, 0.53), radius: 0, toCenter: P(0.5, 0.53), radius: 0.46 * S, options: [])
    }
    // Top gloss.
    if let gloss = NSGradient(starting: NSColor(white: 1, alpha: 0.16),
                              ending: NSColor(white: 1, alpha: 0.0)) {
        gloss.draw(in: NSRect(x: m, y: 0.52 * S, width: rectW, height: 0.48 * S), angle: -90)
    }
    ctx.restoreGraphicsState()

    // Clip everything to the squircle so glows never leak outside.
    ctx.saveGraphicsState()
    squircle.addClip()

    let C = P(0.5, 0.5)
    let tilt: CGFloat = -20 * .pi / 180

    // A point on a tilted ellipse (degrees measured in the ellipse's own frame).
    func orbit(_ a: CGFloat, _ b: CGFloat, _ deg: CGFloat) -> NSPoint {
        let t = deg * .pi / 180
        let x = a * cos(t), y = b * sin(t)
        return NSPoint(x: C.x + x * cos(tilt) - y * sin(tilt),
                       y: C.y + x * sin(tilt) + y * cos(tilt))
    }

    func drawRing(_ a: CGFloat, _ b: CGFloat, _ width: CGFloat, _ color: NSColor) {
        ctx.saveGraphicsState()
        let tf = NSAffineTransform()
        tf.translateX(by: C.x, yBy: C.y)
        tf.rotate(byRadians: tilt)
        tf.concat()
        let ring = NSBezierPath(ovalIn: NSRect(x: -a, y: -b, width: 2 * a, height: 2 * b))
        ring.lineWidth = width
        color.setStroke()
        ring.stroke()
        ctx.restoreGraphicsState()
    }

    // A glowing device node with a bright core.
    func node(_ p: NSPoint, _ r: CGFloat, _ color: NSColor) {
        ctx.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = color.withAlphaComponent(0.85)
        glow.shadowBlurRadius = 0.032 * S
        glow.shadowOffset = .zero
        glow.set()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).fill()
        ctx.restoreGraphicsState()
        NSColor(white: 1, alpha: 0.92).setFill()
        let cr = r * 0.40
        NSBezierPath(ovalIn: NSRect(x: p.x - cr, y: p.y - cr, width: 2 * cr, height: 2 * cr)).fill()
    }

    let outerA = 0.338 * S, outerB = 0.142 * S
    let innerA = 0.250 * S, innerB = 0.104 * S

    // Orbits.
    drawRing(outerA, outerB, 0.010 * S, ringHi)
    drawRing(innerA, innerB, 0.009 * S, ringLo)

    // Nodes that sit behind the chip (upper arc of each orbit).
    node(orbit(outerA, outerB, 152), 0.030 * S, nodeCyan)
    node(orbit(outerA, outerB, 44),  0.026 * S, nodeAmber)
    node(orbit(innerA, innerB, 210), 0.023 * S, nodeMag)

    // Central terminal chip.
    let cw = 0.300 * S
    let chip = rrect(C.x - cw / 2, C.y - cw / 2, cw, cw, 0.066 * S)
    ctx.saveGraphicsState()
    let sh = NSShadow()
    sh.shadowColor = NSColor(white: 0, alpha: 0.5)
    sh.shadowBlurRadius = 0.045 * S
    sh.shadowOffset = NSSize(width: 0, height: -0.014 * S)
    sh.set()
    chipFill.setFill()
    chip.fill()
    ctx.restoreGraphicsState()

    // Neon rim on the chip.
    neon.withAlphaComponent(0.55).setStroke()
    chip.lineWidth = 0.006 * S
    chip.stroke()

    // >_ prompt inside the chip.
    let hh = 0.052 * S
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: C.x - 0.060 * S, y: C.y + hh))
    chevron.line(to: NSPoint(x: C.x - 0.012 * S, y: C.y))
    chevron.line(to: NSPoint(x: C.x - 0.060 * S, y: C.y - hh))
    chevron.lineWidth = 0.020 * S
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    neon.setStroke()
    chevron.stroke()
    neon.setFill()
    rrect(C.x + 0.004 * S, C.y - hh, 0.062 * S, 0.019 * S, 0.0095 * S).fill()

    // A node riding in front of the chip for depth.
    node(orbit(outerA, outerB, -34), 0.030 * S, neon)

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
