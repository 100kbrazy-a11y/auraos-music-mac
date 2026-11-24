import AppKit

// draws the installer window's background: dark glass-like gradient, the title, an arrow from the app to Applications.
// usage: make_dmg_background.swift out.png scale(1|2) withNote(0|1)
let out = CommandLine.arguments[1]
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
let withNote = CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "1"
let W: CGFloat = 660, H: CGFloat = 400
let px = Int(W * scale), py = Int(H * scale)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let gc = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
rep.size = NSSize(width: W, height: H)           // points, so the 2x image is marked as retina
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gc
let ctx = gc.cgContext
ctx.scaleBy(x: scale, y: scale)

func y(_ top: CGFloat) -> CGFloat { H - top }      // measure from the top, like Finder does

// background
NSGradient(colors: [NSColor(red: 0.075, green: 0.075, blue: 0.09, alpha: 1), NSColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)])?.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
// two soft glows
for (cx, cy, r, c) in [(120.0, 70.0, 260.0, NSColor(red: 0.45, green: 0.38, blue: 1.0, alpha: 0.20)), (560.0, 340.0, 240.0, NSColor(red: 1.0, green: 0.38, blue: 0.58, alpha: 0.14))] {
    let g = NSGradient(colors: [c, c.withAlphaComponent(0)])
    g?.draw(fromCenter: NSPoint(x: cx, y: y(cy)), radius: 0, toCenter: NSPoint(x: cx, y: y(cy)), radius: r, options: [])
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, centerY: CGFloat) {
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(white: 1, alpha: alpha), .paragraphStyle: para]
    let h = size * 1.4
    NSAttributedString(string: s, attributes: attrs).draw(in: NSRect(x: 0, y: y(centerY) - h / 2, width: W, height: h))
}
text("Strata Music", size: 26, weight: .semibold, alpha: 0.95, centerY: 52)
text("Drag Strata Music into Applications", size: 13, weight: .medium, alpha: 0.55, centerY: 80)

// arrow between the two icons (icons sit at x=170 and x=490, y=205 from the top)
let ay = y(205)
ctx.setStrokeColor(NSColor(white: 1, alpha: 0.38).cgColor)
ctx.setLineWidth(5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 262, y: ay)); ctx.addLine(to: CGPoint(x: 396, y: ay)); ctx.strokePath()
ctx.move(to: CGPoint(x: 376, y: ay + 18)); ctx.addLine(to: CGPoint(x: 398, y: ay)); ctx.addLine(to: CGPoint(x: 376, y: ay - 18)); ctx.strokePath()

if withNote { text("First time only: right-click Strata Music, then Open", size: 11.5, weight: .regular, alpha: 0.42, centerY: 372) }

NSGraphicsContext.restoreGraphicsState()
if let d = rep.representation(using: .png, properties: [:]) { try? d.write(to: URL(fileURLWithPath: out)) }
