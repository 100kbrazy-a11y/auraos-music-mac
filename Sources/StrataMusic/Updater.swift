import Foundation
import SwiftUI
import AppKit

/// checks GitHub for a newer release (tags like mac-v1.2.0) and opens the download
@MainActor
final class Updater: ObservableObject {
    static let repo = "100kbrazy-a11y/auraos-music-mac"

    struct Asset: Decodable { var name: String; var browserDownloadUrl: String; var size: Int }
    struct Release: Decodable { var tagName: String; var name: String?; var body: String?; var htmlUrl: String; var assets: [Asset]
        var version: String { String(tagName.drop(while: { !$0.isNumber })) }
    }

    @Published var available: Release?
    @Published var status = ""
    @Published var busy = false

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }

    private static func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 } }
    private static func newer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) { let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0; if p != q { return p > q } }
        return false
    }

    func check(silent: Bool = false) async {
        busy = true; defer { busy = false }
        if !silent { status = "Checking…" }
        guard let u = URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=10") else { return }
        var req = URLRequest(url: u); req.setValue("Strata Music for Mac", forHTTPHeaderField: "User-Agent"); req.timeoutInterval = 15
        do {
            let (d, _) = try await URLSession.shared.data(for: req)
            let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
            let list = try dec.decode([Release].self, from: d).filter { $0.tagName.hasPrefix("mac-v") }
            if let r = list.first, Self.newer(r.version, than: Self.current) { available = r; status = "Version \(r.version) is available" }
            else { available = nil; status = silent ? "" : "You're up to date (\(Self.current))" }
        } catch { if !silent { status = "Couldn't check: \(error.localizedDescription)" } }
    }

    func install() async {
        guard let r = available, let a = r.assets.first(where: { $0.name.hasSuffix(".dmg") }) ?? r.assets.first, let u = URL(string: a.browserDownloadUrl) else { return }
        busy = true; status = "Downloading \(r.version)…"; defer { busy = false }
        do {
            let (tmp, _) = try await URLSession.shared.download(from: u)
            let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(a.name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            status = "Downloaded to Downloads. Drag Strata Music to Applications."
            NSWorkspace.shared.open(dest)
        } catch { status = "Download failed: \(error.localizedDescription)" }
    }
}
