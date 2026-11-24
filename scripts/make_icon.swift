import AppKit

// draws the app icon (a purple-to-pink rounded square with a white note) into an .iconset folder
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    let p = CGFloat(px)
    let r = NSRect(x: p * 0.09, y: p * 0.09, width: p * 0.82, height: p * 0.82)
    let path = NSBezierPath(roundedRect: r, xRadius: p * 0.19, yRadius: p * 0.19)
    NSGradient(colors: [NSColor(red: 0.40, green: 0.30, blue: 0.95, alpha: 1), NSColor(red: 0.96, green: 0.36, blue: 0.56, alpha: 1)])?.draw(in: path, angle: -55)
    if let sym = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) {
        let cfg = NSImage.SymbolConfiguration(pointSize: p * 0.46, weight: .bold).applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let img = sym.withSymbolConfiguration(cfg) {
            let s = img.size
            img.draw(in: NSRect(x: (p - s.width) / 2, y: (p - s.height) / 2, width: s.width, height: s.height))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes {
    if let d = render(px) { try? d.write(to: URL(fileURLWithPath: out).appendingPathComponent("icon_\(name).png")) }
}
