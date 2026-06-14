import AppKit

// Renders the DMG window background PNG.
// Usage:  swift dmg-background.swift <output.png>

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
let w = 600.0, h = 400.0

let image = NSImage(size: NSSize(width: w, height: h))
image.lockFocus()

// Soft vertical gradient backdrop.
if let grad = NSGradient(starting: NSColor(calibratedWhite: 0.98, alpha: 1),
                         ending: NSColor(calibratedWhite: 0.90, alpha: 1)) {
    grad.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)
}

// Title text near the top.
let title = NSMutableParagraphStyle()
title.alignment = .center
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.20, alpha: 1),
    .paragraphStyle: title
]
NSAttributedString(string: "Install SSH Tunnel Manager", attributes: titleAttrs)
    .draw(in: NSRect(x: 0, y: h - 64, width: w, height: 28))

// Subtitle / instruction.
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .regular),
    .foregroundColor: NSColor(calibratedWhite: 0.40, alpha: 1),
    .paragraphStyle: title
]
NSAttributedString(string: "Drag the app onto the Applications folder", attributes: subAttrs)
    .draw(in: NSRect(x: 0, y: h - 92, width: w, height: 20))

// Arrow pointing from the app (left) to Applications (right), at icon height.
let arrowY = 205.0          // distance from BOTTOM (matches Finder icon row visually)
let stroke = NSColor(calibratedWhite: 0.55, alpha: 1)
stroke.setStroke()
stroke.setFill()

let shaft = NSBezierPath()
shaft.lineWidth = 6
shaft.lineCapStyle = .round
shaft.move(to: NSPoint(x: 250, y: arrowY))
shaft.line(to: NSPoint(x: 348, y: arrowY))
shaft.stroke()

let head = NSBezierPath()
head.move(to: NSPoint(x: 360, y: arrowY))
head.line(to: NSPoint(x: 338, y: arrowY + 14))
head.line(to: NSPoint(x: 338, y: arrowY - 14))
head.close()
head.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to render background\n".utf8))
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: outPath))
} catch {
    FileHandle.standardError.write(Data("failed to write \(outPath): \(error)\n".utf8))
    exit(1)
}
