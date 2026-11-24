import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - what the YouTube page has been doing

@MainActor
final class EngineLog: ObservableObject {
    static let shared = EngineLog()
    @Published private(set) var lines: [String] = []
    private let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    func add(_ s: String) {
        lines.append("\(fmt.string(from: Date()))  \(s)")
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
    }
    func clear() { lines = [] }
    var text: String { lines.joined(separator: "\n") }
}

// MARK: - did the last run end properly?

enum CrashGuard {
    private static var flag: URL { Disk.dir.appendingPathComponent("running.flag") }

    /// call once at launch: true when the last run never reached a clean quit
    static func begin() -> Bool {
        let crashed = FileManager.default.fileExists(atPath: flag.path)
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        try? "\(Date().timeIntervalSince1970) \(v)".write(to: flag, atomically: true, encoding: .utf8)
        return crashed
    }
    static func end() { try? FileManager.default.removeItem(at: flag) }
}

enum Diagnostics {
    /// the newest crash report macOS wrote for this app (first part of it), if any
    private static func crashReport() -> String {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let mine = files.filter { $0.lastPathComponent.hasPrefix("StrataMusic") || $0.lastPathComponent.hasPrefix("Strata Music") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        guard let f = mine.first, let t = try? String(contentsOf: f, encoding: .utf8) else { return "(no crash report from macOS found)" }
        return "\(f.lastPathComponent)\n" + String(t.prefix(30_000))
    }

    @MainActor static func text(library: Library?) -> String {
        var model = [CChar](repeating: 0, count: 64); var n = 64
        sysctlbyname("hw.model", &model, &n, nil, 0)
        var s = "Strata Music \(Updater.current)\n"
        s += "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(String(cString: model))\n"
        s += "Songs: \(library?.songs.count ?? 0), folders: \(library?.folders.count ?? 0)\n"
        s += "Enhanced engine: \(UserDefaults.standard.bool(forKey: "enhancedEngine"))\n\n"
        s += "--- YouTube engine log ---\n\(EngineLog.shared.text)\n\n"
        s += "--- newest crash report ---\n\(crashReport())\n"
        return s
    }

    @MainActor static func save(library: Library?) {
        let p = NSSavePanel(); p.allowedContentTypes = [.plainText]; p.nameFieldStringValue = "Strata Music diagnostics.txt"
        if p.runModal() == .OK, let u = p.url { try? text(library: library).write(to: u, atomically: true, encoding: .utf8) }
    }

    /// "Strata Music didn't close properly last time"
    @MainActor static func askAfterCrash() {
        let a = NSAlert()
        a.messageText = "Strata Music didn't close properly last time"
        a.informativeText = "If it crashed, you can save a diagnostics file (version, the YouTube log and the newest crash report) to send along when you report it."
        a.addButton(withTitle: "Save Diagnostics…")
        a.addButton(withTitle: "Not Now")
        if a.runModal() == .alertFirstButtonReturn { save(library: Library.main) }
    }
}

// MARK: - "Test YouTube"

struct HealthStep: Identifiable {
    let id = UUID()
    var name: String
    var ok: Bool?          // nil while it runs
    var detail = ""
}

@MainActor
final class YtHealth: ObservableObject {
    @Published private(set) var steps: [HealthStep] = []
    @Published private(set) var running = false

    func run() async {
        guard !running else { return }
        running = true; steps = []
        defer { running = false }
        var videoID = ""
        var source: YtEngine.Source?

        if await step("Open the YouTube page", { try await YtEngine.shared.use { }; return "ready" }) == nil { return }
        guard let found = await step("Search", {
            let r = try await YtEngine.shared.search("daft punk one more time", type: "song")
            guard let first = r.first(where: { $0.kind == "song" }) else { throw YtError("no songs came back") }
            videoID = first.id
            return "\(r.count) results, first: \(first.title)"
        }) else { return }
        _ = found
        if await step("Find the audio address", {
            let s = try await YtEngine.shared.source(for: videoID)
            source = s
            return "\(s.ext), about \(s.kbps) kbps"
        }) == nil { return }
        guard let src = source, let url = URL(string: src.url) else { return }
        _ = await step("Download the first 2 KB", {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
            if !src.ua.isEmpty { req.setValue(src.ua, forHTTPHeaderField: "User-Agent") }
            if !src.origin.isEmpty { req.setValue(src.origin, forHTTPHeaderField: "Origin"); req.setValue(src.origin + "/", forHTTPHeaderField: "Referer") }
            let (d, r) = try await URLSession.shared.data(for: req)
            let code = (r as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 || code == 206 else { throw YtError("YouTube answered \(code)") }
            return "\(d.count) bytes"
        })
    }

    /// runs one check; nil if it failed (the row says why)
    private func step(_ name: String, _ f: () async throws -> String) async -> String? {
        steps.append(HealthStep(name: name, ok: nil))
        let i = steps.count - 1
        let t0 = Date()
        do {
            let d = try await f()
            steps[i].ok = true; steps[i].detail = d + String(format: "  (%.1f s)", Date().timeIntervalSince(t0))
            return d
        } catch {
            let m = (error as? YtError)?.errorDescription ?? error.localizedDescription
            steps[i].ok = false; steps[i].detail = m
            EngineLog.shared.add("Test failed at “\(name)”: \(m)")
            return nil
        }
    }
}

// MARK: - Settings > Advanced

struct AdvancedSettings: View {
    @EnvironmentObject var lib: Library
    @ObservedObject var log = EngineLog.shared
    @StateObject private var health = YtHealth()

    var body: some View {
        Form {
            Section("Shortcuts and scripts") {
                Text("Strata answers to strata:// links, so the Shortcuts app (Open URL), Raycast, Alfred and the Terminal can control it.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("strata://toggle · play · pause · next · previous · like · shuffle · repeat\nstrata://play?q=song or artist\nstrata://playlist?name=Road Trip&shuffle=1\nstrata://volume?level=0.5")
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            }
            Section("YouTube") {
                HStack {
                    Button(health.running ? "Testing…" : "Test YouTube") { Task { await health.run() } }.disabled(health.running)
                    Button("Reset the YouTube page") { YtEngine.shared.reset(); log.add("Reset by you") }
                }
                ForEach(health.steps) { s in
                    HStack(alignment: .top, spacing: 8) {
                        if s.ok == nil { ProgressView().controlSize(.small) }
                        else { Image(systemName: s.ok == true ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(s.ok == true ? Color.green : Color.red) }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name).font(.system(size: 13, weight: .medium))
                            if !s.detail.isEmpty { Text(s.detail).font(.system(size: 12)).foregroundStyle(.secondary) }
                        }
                    }
                }
                Text("Search and downloads run through a hidden YouTube page. If they stop working, this shows which step fails. After three failures in a row the page resets itself.").font(.callout).foregroundStyle(.secondary)
            }
            Section("Engine log") {
                ScrollView {
                    Text(log.lines.isEmpty ? "Nothing yet." : log.text).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(height: 150)
                HStack {
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(log.text, forType: .string) }
                    Button("Clear") { log.clear() }
                    Spacer()
                    Button("Save Diagnostics…") { Diagnostics.save(library: lib) }
                }
            }
        }
        .formStyle(.grouped)
    }
}


// MARK: - stalls

/// Notices when the app stops answering for a moment (the "it freezes, then goes back to normal" kind of thing) and writes how long it lasted
/// and what the app was doing, so a stall can be traced from the diagnostics instead of guessed at.
enum HangWatch {
    private static var started = false
    private static let beat = HangBeat()

    @MainActor static func start() {
        if started { return }
        started = true
        let b = beat
        let t = Thread {
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                let sent = Date()
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { sem.signal() }
                if sem.wait(timeout: .now() + 0.7) == .timedOut {
                    sem.wait()
                    let gap = Date().timeIntervalSince(sent)
                    let what = b.note
                    Task { @MainActor in EngineLog.shared.add(String(format: "App stalled for %.1f s (%@)", gap, what.isEmpty ? "nothing noted" : what)) }
                }
            }
        }
        t.name = "strata.hangwatch"; t.qualityOfService = .utility; t.start()
    }

    /// short note on what's going on, shown next to a stall in the log
    static func note(_ s: String) { beat.set(s) }
}

private final class HangBeat {
    private let lock = NSLock()
    private var _note = ""
    var note: String { lock.lock(); defer { lock.unlock() }; return _note }
    func set(_ s: String) { lock.lock(); _note = s; lock.unlock() }
}
