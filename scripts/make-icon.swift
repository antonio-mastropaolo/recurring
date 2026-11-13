// Renders the Observatory app icon: machined graphite squircle (#0A0B0D -> #191C20),
// precision hairline bezel (#2C3138), signal-amber (#FFB020) ↻ dial, mint (#3DD4A7) live pip.
// Run via scripts/make-icon.sh.
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let inset: CGFloat = 96
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 186, yRadius: 186)

// Machined graphite body
let bodyGrad = NSGradient(
    starting: NSColor(calibratedRed: 25.0 / 255.0, green: 28.0 / 255.0, blue: 32.0 / 255.0, alpha: 1),
    ending: NSColor(calibratedRed: 10.0 / 255.0, green: 11.0 / 255.0, blue: 13.0 / 255.0, alpha: 1)
)!
bodyGrad.draw(in: squircle, angle: -90)

// Outer hairline bezel
NSColor(calibratedRed: 44.0 / 255.0, green: 49.0 / 255.0, blue: 56.0 / 255.0, alpha: 1).setStroke()
squircle.lineWidth = 8
squircle.stroke()

// Subtle Observatory dial ring
let center = NSPoint(x: size / 2, y: size / 2)
let dialR: CGFloat = 290
let dialRing = NSBezierPath(ovalIn: NSRect(x: center.x - dialR, y: center.y - dialR, width: dialR * 2, height: dialR * 2))
NSColor(calibratedRed: 44.0 / 255.0, green: 49.0 / 255.0, blue: 56.0 / 255.0, alpha: 0.75).setStroke()
dialRing.lineWidth = 6
dialRing.stroke()

// 12 precision tick marks around the Observatory dial
for idx in 0..<12 {
    let angle = CGFloat(idx) * (.pi * 2 / 12)
    let r1: CGFloat = (idx % 3 == 0) ? 258 : 270
    let r2: CGFloat = 290
    let p1 = NSPoint(x: center.x + cos(angle) * r1, y: center.y + sin(angle) * r1)
    let p2 = NSPoint(x: center.x + cos(angle) * r2, y: center.y + sin(angle) * r2)
    let tick = NSBezierPath()
    tick.move(to: p1)
    tick.line(to: p2)
    tick.lineWidth = (idx % 3 == 0) ? 7 : 4
    NSColor(calibratedRed: 1.0, green: 0.69, blue: 0.125, alpha: (idx % 3 == 0) ? 0.55 : 0.25).setStroke()
    tick.stroke()
}

// Signal-amber radial glow behind the ↻ mark
let glowR: CGFloat = 220
let glowPath = NSBezierPath(ovalIn: NSRect(x: center.x - glowR, y: center.y - glowR, width: glowR * 2, height: glowR * 2))
let glowGrad = NSGradient(
    starting: NSColor(calibratedRed: 1.0, green: 0.69, blue: 0.125, alpha: 0.20),
    ending: NSColor(calibratedRed: 1.0, green: 0.69, blue: 0.125, alpha: 0.0)
)!
glowGrad.draw(in: glowPath, relativeCenterPosition: .zero)

// Primary signal-amber ↻ glyph
let glyph = "↻" as NSString
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 430, weight: .heavy),
    .foregroundColor: NSColor(calibratedRed: 1.0, green: 0.69, blue: 0.125, alpha: 1),
]
let g = glyph.size(withAttributes: attrs)
glyph.draw(at: NSPoint(x: (size - g.width) / 2, y: (size - g.height) / 2 + 8), withAttributes: attrs)

// Mint live-telemetry pip in upper-right corner of the squircle
let pipCenter = NSPoint(x: size - inset - 115, y: size - inset - 115)
let haloRect = NSRect(x: pipCenter.x - 36, y: pipCenter.y - 36, width: 72, height: 72)
NSColor(calibratedRed: 0.239, green: 0.831, blue: 0.655, alpha: 0.24).setFill()
NSBezierPath(ovalIn: haloRect).fill()

let pipRect = NSRect(x: pipCenter.x - 18, y: pipCenter.y - 18, width: 36, height: 36)
NSColor(calibratedRed: 0.239, green: 0.831, blue: 0.655, alpha: 1).setFill()
NSBezierPath(ovalIn: pipRect).fill()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
