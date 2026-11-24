import Foundation
import SwiftUI
import AppKit

/// checks GitHub for a newer release (tags like mac-v1.2.0), asks the person, and swaps the app for the new one right here
@MainActor
final class Updater: ObservableObject {
    static let repo = "100kbrazy-a11y/auraos-music-mac"

    struct Asset: Decodable { var name: String; var browserDownloadUrl: String; var size: Int }
    struct Release: Decodable { var tagName: String; var name: String?; var body: String?; var htmlUrl: String; var assets: [Asset]
        var version: String { String(tagName.drop(while: { !$0.isNumber })) }
        /// the bullet points of the release notes (the small print about Gatekeeper is left out)
        var bullets: [String] {
            (body ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("- ") }.map { String($0.dropFirst(2)) }
        }
    }

    @Published var available: Release?
    @Published var status = ""
    @Published var busy = false
    @Published var progress: Double?          // 0...1 while the new version downloads
    @Published var failed = false
    /// the little centred window: "Update available" (or, after a manual check, "You're up to date")
    @Published var showPrompt = false

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }

    static func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0.prefix(while: { $0.isNumber })) ?? 0 } }
    static func newer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) { let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0; if p != q { return p > q } }
        return false
    }

    /// [silent]: the automatic check. It only speaks up when there is something new that the person hasn't already said "nah" to.
    func check(silent: Bool = false) async {
        guard !busy else { return }
        busy = true; failed = false; defer { busy = false }
        if !silent { status = "Checking…" }
        guard let u = URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=10") else { return }
        var req = URLRequest(url: u); req.setValue("Strata Music for Mac", forHTTPHeaderField: "User-Agent"); req.timeoutInterval = 15
        do {
            let (d, _) = try await URLSession.shared.data(for: req)
            let dec = JSONDecoder(); dec.keyDecodingStrategy = .convertFromSnakeCase
            let list = try dec.decode([Release].self, from: d).filter { $0.tagName.hasPrefix("mac-v") }
            if let r = list.first, Self.newer(r.version, than: Self.current) {
                available = r; status = "Version \(r.version) is available"
                if !silent || UserDefaults.standard.string(forKey: "skipVersion") != r.version { showPrompt = true }
            } else {
                available = nil; status = silent ? "" : "You're up to date (\(Self.current))"
                if !silent { showPrompt = true }
            }
        } catch {
            if !silent { status = "Couldn't check: \(error.localizedDescription)"; failed = true; showPrompt = true }
        }
    }

    /// "Nah, I'm good": closes the window and stays quiet about this version (a newer one asks again)
    func dismiss() {
        if let r = available { UserDefaults.standard.set(r.version, forKey: "skipVersion") }
        showPrompt = false
    }

    // MARK: installing

    func install() async {
        guard let r = available, !busy else { return }
        let zip = r.assets.first { $0.name.hasSuffix(".zip") }
        let dmg = r.assets.first { $0.name.hasSuffix(".dmg") }
        let app = Bundle.main.bundleURL
        let parent = app.deletingLastPathComponent().path
        // replace the app in place only when we're allowed to (not running from the disk image, not from a quarantine sandbox)
        let canReplace = zip != nil && app.pathExtension == "app" && FileManager.default.isWritableFile(atPath: parent)
            && !app.path.hasPrefix("/Volumes/") && !app.path.contains("/AppTranslocation/")
        busy = true; failed = false; progress = 0; status = "Downloading \(r.version)…"
        defer { busy = false; progress = nil }
        do {
            if canReplace, let z = zip, let url = URL(string: z.browserDownloadUrl) {
                let file = try await Self.download(url) { [weak self] p in Task { @MainActor in self?.progress = p } }
                status = "Installing…"; progress = nil
                let fresh = try await Self.unpack(file)
                try Self.swapAndRelaunch(new: fresh, over: app)
            } else if let d = dmg ?? zip, let url = URL(string: d.browserDownloadUrl) {
                // can't swap the app by itself from here: download the disk image and open it
                let file = try await Self.download(url) { [weak self] p in Task { @MainActor in self?.progress = p } }
                let dest = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent(d.name)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: file, to: dest)
                status = "Downloaded to Downloads. Drag Strata Music to Applications."
                showPrompt = false
                NSWorkspace.shared.open(dest)
            } else { throw UpdateError.message("This release has no download.") }
        } catch {
            failed = true
            status = "The update didn't work: \((error as? UpdateError)?.text ?? error.localizedDescription)"
        }
    }

    enum UpdateError: Error { case message(String); var text: String { if case .message(let m) = self { return m }; return "" } }

    private final class Fetch: NSObject, URLSessionDownloadDelegate {
        let onProgress: @Sendable (Double) -> Void
        var cont: CheckedContinuation<URL, Error>?
        init(_ p: @escaping @Sendable (Double) -> Void) { onProgress = p }
        func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData b: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
            if e > 0 { onProgress(min(1, Double(w) / Double(e))) }
        }
        func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo loc: URL) {
            if let h = t.response as? HTTPURLResponse, !(200..<300).contains(h.statusCode) { cont?.resume(throwing: UpdateError.message("the download was refused (HTTP \(h.statusCode))")); cont = nil; return }
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent("strata-update-" + UUID().uuidString)
            do { try FileManager.default.moveItem(at: loc, to: keep); cont?.resume(returning: keep) } catch { cont?.resume(throwing: error) }
            cont = nil
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
            if let e = e { cont?.resume(throwing: e); cont = nil }
        }
    }

    private static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let f = Fetch(progress)
        let session = URLSession(configuration: .default, delegate: f, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { c in
            f.cont = c
            var req = URLRequest(url: url); req.setValue("Strata Music for Mac", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: req).resume()
        }
    }

    /// unzips the download into its own folder and returns the .app inside
    private static func unpack(_ zip: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("strata-new-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", zip.path, dir.path]
            try p.run(); p.waitUntilExit()
            try? FileManager.default.removeItem(at: zip)
            guard p.terminationStatus == 0 else { throw UpdateError.message("the download couldn't be unpacked") }
            guard let app = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" })
            else { throw UpdateError.message("the download has no app inside") }
            return app
        }.value
    }

    /// a tiny script waits for this app to quit, puts the new copy in its place (the old one comes back if that fails) and opens it
    private static func swapAndRelaunch(new: URL, over app: URL) throws {
        let script = """
        #!/bin/sh
        PID="$1"; NEW="$2"; DEST="$3"
        i=0; while kill -0 "$PID" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.3; i=$((i+1)); done
        OLD="$DEST.previous"
        rm -rf "$OLD"
        if mv "$DEST" "$OLD"; then
          if ditto "$NEW" "$DEST"; then rm -rf "$OLD"; else rm -rf "$DEST"; mv "$OLD" "$DEST"; fi
        fi
        xattr -cr "$DEST" 2>/dev/null
        rm -rf "$(dirname "$NEW")"
        open "$DEST"
        rm -f "$0"
        """
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("strata-update-\(UUID().uuidString).sh")
        try script.write(to: path, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [path.path, String(ProcessInfo.processInfo.processIdentifier), new.path, app.path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run()
        NSApp.terminate(nil)
    }
}

// MARK: - the little centred window

struct UpdatePrompt: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        ZStack {
            if updater.showPrompt {
                Color.black.opacity(0.45).ignoresSafeArea()
                    .onTapGesture { if !updater.busy { updater.showPrompt = false } }
                    .transition(.opacity)
                card.transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: updater.showPrompt)
    }

    @ViewBuilder private var card: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            if let r = updater.available {
                Text("Update available").font(.system(size: 19, weight: .bold))
                Text("Strata Music \(r.version) is ready. You have \(Updater.current).").font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                let notes = Array(r.bullets.prefix(5))
                if !notes.isEmpty && !updater.busy {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(notes, id: \.self) { n in
                            HStack(alignment: .top, spacing: 6) { Text("•"); Text(n).fixedSize(horizontal: false, vertical: true) }.font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
                }
                if updater.busy {
                    VStack(spacing: 6) {
                        if let p = updater.progress { ProgressView(value: p) } else { ProgressView().controlSize(.small) }
                        Text(updater.status).font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.top, 4)
                } else {
                    if updater.failed { Text(updater.status).font(.system(size: 12)).foregroundStyle(.red).multilineTextAlignment(.center) }
                    HStack(spacing: 10) {
                        Button("Nah, I'm good") { updater.dismiss() }.buttonStyle(.bordered)
                        Button("Yes, of course") { Task { await updater.install() } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    }.controlSize(.large).padding(.top, 4)
                }
            } else {
                Text(updater.failed ? "Couldn't check" : "You're up to date").font(.system(size: 19, weight: .bold))
                Text(updater.failed ? updater.status : "Strata Music \(Updater.current) is the newest version.").font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Nice") { updater.showPrompt = false }.buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction).padding(.top, 4)
            }
        }
        .padding(24)
        .frame(width: 330)
        .glass(26)
        .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
    }
}
