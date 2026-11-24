import SwiftUI
import CoreImage
import AppKit
import ImageIO

enum Theme {
    static let accent = Color(red: 0.62, green: 0.50, blue: 1.0)
}

func fmtTime(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let t = Int(s.rounded())
    return String(format: "%d:%02d", t / 60, t % 60)
}

/// a small stable hash (String.hashValue changes on every launch)
func fnv(_ data: Data) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in data { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return String(h, radix: 16)
}

func primaryArtist(_ s: String) -> String {
    var out = s
    for sep in [" feat.", " feat ", " ft.", " featuring ", ", ", " & ", ";", " x "] {
        if let r = out.range(of: sep, options: .caseInsensitive) { out = String(out[out.startIndex..<r.lowerBound]) }
    }
    return out.trimmingCharacters(in: .whitespaces)
}

// MARK: - cover pictures

enum Covers {
    static let cache: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 700; return c }()
    private static let lock = NSLock()
    private static var accents: [String: Color] = [:]

    static func url(_ s: Song) -> URL? { s.cover.isEmpty ? nil : Disk.dir.appendingPathComponent("covers/\(s.cover)") }

    private static func key(_ s: Song, _ maxPixel: Int) -> NSString { "\(s.cover)|\(maxPixel)" as NSString }

    /// a picture that was already decoded (cheap, safe to ask while drawing)
    static func cached(_ s: Song?, maxPixel: Int) -> NSImage? {
        guard let s = s, !s.cover.isEmpty else { return nil }
        return cache.object(forKey: key(s, maxPixel))
    }

    nonisolated static func decode(_ u: URL, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// a picture no bigger than [maxPixel] (decoded once, then cached). This one decodes right now, so use [load] while drawing lists.
    static func image(_ s: Song?, maxPixel: Int) -> NSImage? {
        guard let s = s, let u = url(s) else { return nil }
        if let c = cache.object(forKey: key(s, maxPixel)) { return c }
        guard let img = decode(u, maxPixel: maxPixel) else { return nil }
        cache.setObject(img, forKey: key(s, maxPixel))
        return img
    }

    /// the same, decoded away from the main thread
    static func load(_ s: Song, maxPixel: Int) async -> NSImage? {
        if let c = cache.object(forKey: key(s, maxPixel)) { return c }
        guard let u = url(s) else { return nil }
        let img = await Task.detached(priority: .userInitiated) { decode(u, maxPixel: maxPixel) }.value
        if let img = img { cache.setObject(img, forKey: key(s, maxPixel)) }
        return img
    }

    // MARK: the cover's strongest colour (used for the player's glow and the buttons)

    nonisolated private static func computeAccent(_ u: URL) -> Color {
        var result = Theme.accent
        if let src = CGImageSourceCreateWithURL(u as CFURL, nil),
           let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 24] as CFDictionary) {
            let w = img.width, h = img.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let cs = CGColorSpaceCreateDeviceRGB()
            px.withUnsafeMutableBytes { ptr in
                if let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
            }
            var r = 0.0, g = 0.0, b = 0.0, wsum = 0.0
            for i in 0..<(w * h) {
                let pr = Double(px[i * 4]) / 255, pg = Double(px[i * 4 + 1]) / 255, pb = Double(px[i * 4 + 2]) / 255
                let mx = max(pr, pg, pb), mn = min(pr, pg, pb)
                let weight = (mx - mn) * 2 + 0.05 + (mx > 0.25 ? 0.2 : 0)
                r += pr * weight; g += pg * weight; b += pb * weight; wsum += weight
            }
            if wsum > 0 {
                var cr = r / wsum, cg = g / wsum, cb = b / wsum
                let m = max(cr, cg, cb)
                if m > 0 && m < 0.7 { let k = 0.7 / m; cr *= k; cg *= k; cb *= k }
                result = Color(red: min(1, cr), green: min(1, cg), blue: min(1, cb))
            }
        }
        return result
    }

    static func cachedAccent(_ s: Song?) -> Color? {
        guard let s = s, !s.cover.isEmpty else { return Theme.accent }
        lock.lock(); defer { lock.unlock() }
        return accents[s.cover]
    }

    static func accent(_ s: Song?) -> Color {
        guard let s = s, let u = url(s) else { return Theme.accent }
        if let c = cachedAccent(s) { return c }
        let c = computeAccent(u)
        lock.lock(); accents[s.cover] = c; lock.unlock()
        return c
    }

    static func accentAsync(_ s: Song?) async -> Color {
        guard let s = s, let u = url(s) else { return Theme.accent }
        if let c = cachedAccent(s) { return c }
        let c = await Task.detached(priority: .userInitiated) { computeAccent(u) }.value
        lock.lock(); accents[s.cover] = c; lock.unlock()
        return c
    }
}

extension Covers {
    static let softCache = NSCache<NSString, NSImage>()
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func cachedSoft(_ s: Song?) -> NSImage? { s.flatMap { softCache.object(forKey: $0.cover as NSString) } }

    /// a blurred, colourful copy of the cover for backgrounds. The blur is done once on a small picture; drawing it larger keeps it soft,
    /// so the window never has to blur anything while it animates.
    static func soft(_ s: Song?) async -> NSImage? {
        guard let s = s, let u = url(s) else { return nil }
        if let c = softCache.object(forKey: s.cover as NSString) { return c }
        let img: NSImage? = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 96] as CFDictionary) else { return nil }
            let input = CIImage(cgImage: cg)
            let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 7).cropped(to: input.extent)
            let tuned = blurred.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35, kCIInputBrightnessKey: -0.04])
            guard let out = ciContext.createCGImage(tuned, from: input.extent) else { return nil }
            return NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
        }.value
        if let img = img { softCache.setObject(img, forKey: s.cover as NSString) }
        return img
    }
}

/// a soft, blurred version of a cover that fills whatever space it is given
struct SoftCover: View {
    let song: Song?
    @State private var img: NSImage?

    var body: some View {
        Group {
            if let i = img ?? Covers.cachedSoft(song) {
                Image(nsImage: i).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else { Color.clear }
        }
        .task(id: song?.cover ?? "") { img = await Covers.soft(song) }
    }
}

struct CoverView: View {
    let song: Song?
    var size: CGFloat
    var radius: CGFloat = 8
    @State private var loaded: (key: String, image: NSImage)?

    private var px: Int { Int(size * 2) }
    private var key: String { "\(song?.cover ?? "")|\(px)" }

    var body: some View {
        Group {
            if let img = Covers.cached(song, maxPixel: px) ?? (loaded?.key == key ? loaded?.image : nil) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.20), Color(white: 0.11)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .task(id: key) {
            guard let s = song, !s.cover.isEmpty, Covers.cached(s, maxPixel: px) == nil else { return }
            if let img = await Covers.load(s, maxPixel: px) { loaded = (key, img) }
        }
    }
}

// MARK: - glass

extension View {
    /// Liquid Glass on macOS 26 and later, a blurred material (the same look, one step simpler) on older macOS
    @ViewBuilder
    func glass(_ radius: CGFloat = 20, tint: Color? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            self.blurPanel(radius, tint)
        }
        #else
        self.blurPanel(radius, tint)
        #endif
    }

    func blurPanel(_ radius: CGFloat, _ tint: Color?) -> some View {
        self
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.ultraThinMaterial)
                    if let t = tint { RoundedRectangle(cornerRadius: radius, style: .continuous).fill(t.opacity(0.14)) }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
