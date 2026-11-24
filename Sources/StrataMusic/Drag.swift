import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Dragging songs in and out of the app.
/// - one song dragged out is the real file (to the desktop, a folder, a browser upload…)
/// - several songs, an album or a playlist dragged out become a "music pack": when you let go, a small window asks for the title and the audio format, then one .zip is made
/// - inside the app, any of them can be dropped on a playlist in the sidebar
enum SongDrag {
    static let typeID = "com.strata.music.songs"
    static var type: UTType { UTType(exportedAs: typeID) }

    static func provider(_ songs: [Song], name: String) -> NSItemProvider {
        let p: NSItemProvider
        if songs.count == 1, let s = songs.first {
            p = NSItemProvider(contentsOf: s.url) ?? NSItemProvider()
            p.suggestedName = "\(s.shownArtist) - \(s.title)"
        } else {
            p = NSItemProvider()
            p.suggestedName = name
            let n = songs.count
            p.registerFileRepresentation(forTypeIdentifier: UTType.zip.identifier, fileOptions: [], visibility: .all) { done in
                let progress = Progress(totalUnitCount: 1)
                DispatchQueue.global(qos: .userInitiated).async {
                    // the other app has just received the drop: ask what to make
                    let box = ChoiceBox()
                    let sem = DispatchSemaphore(value: 0)
                    Task { @MainActor in box.value = PackPrompt.ask(count: n, suggested: name); sem.signal() }
                    sem.wait()
                    guard let choice = box.value else { done(nil, false, CocoaError(.userCancelled)); return }
                    Task {
                        do { done(try await MusicPack.build(songs, title: choice.title, format: choice.format), false, nil) }
                        catch { done(nil, false, error) }
                    }
                }
                return progress
            }
        }
        if let data = try? JSONEncoder().encode(songs.map { $0.id }) {
            p.registerDataRepresentation(forTypeIdentifier: typeID, visibility: .ownProcess) { $0(data, nil); return nil }
        }
        return p
    }

    /// the song ids carried by something dropped inside the app
    static func ids(from providers: [NSItemProvider], _ done: @escaping @MainActor ([String]) -> Void) {
        let box = IDBox()
        let group = DispatchGroup()
        for p in providers where p.hasItemConformingToTypeIdentifier(typeID) {
            group.enter()
            p.loadDataRepresentation(forTypeIdentifier: typeID) { d, _ in
                if let d = d, let ids = try? JSONDecoder().decode([String].self, from: d) { box.add(ids) }
                group.leave()
            }
        }
        group.notify(queue: .main) { let all = box.ids; Task { @MainActor in done(all) } }
    }

    static func isOurs(_ p: NSItemProvider) -> Bool { p.hasItemConformingToTypeIdentifier(typeID) }
}

private final class IDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [String] = []
    func add(_ x: [String]) { lock.lock(); _ids += x; lock.unlock() }
    var ids: [String] { lock.lock(); defer { lock.unlock() }; return _ids }
}

struct PackChoice { var title: String; var format: ExportFormat }

private final class ChoiceBox: @unchecked Sendable { var value: PackChoice? }

@MainActor
enum PackPrompt {
    static func ask(count: Int, suggested: String) -> PackChoice? {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Create a music pack"
        a.informativeText = "\(count) songs will be put in one .zip file, with a pack.json that lists them."
        a.addButton(withTitle: "Create Pack")
        a.addButton(withTitle: "Cancel")
        func label(_ s: String) -> NSTextField { let t = NSTextField(labelWithString: s); t.font = .systemFont(ofSize: 11, weight: .semibold); t.textColor = .secondaryLabelColor; return t }
        let field = NSTextField(string: suggested)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        pop.addItems(withTitles: ExportFormat.allCases.map { $0.rawValue })
        let note = NSTextField(wrappingLabelWithString: ExportFormat.original.note)
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 320
        let handler = FormatNote(pop: pop, note: note)
        pop.target = handler; pop.action = #selector(FormatNote.changed)
        let stack = NSStackView(views: [label("Title"), field, label("Format"), pop, note])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 150)
        a.accessoryView = stack
        a.window.initialFirstResponder = field
        let r = a.runModal()
        withExtendedLifetime(handler) {}
        guard r == .alertFirstButtonReturn else { return nil }
        let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = ExportFormat.allCases[max(0, min(pop.indexOfSelectedItem, ExportFormat.allCases.count - 1))]
        return PackChoice(title: t.isEmpty ? suggested : t, format: f)
    }
}

@MainActor
private final class FormatNote: NSObject {
    let pop: NSPopUpButton, note: NSTextField
    init(pop: NSPopUpButton, note: NSTextField) { self.pop = pop; self.note = note }
    @objc func changed() {
        let i = max(0, min(pop.indexOfSelectedItem, ExportFormat.allCases.count - 1))
        note.stringValue = ExportFormat.allCases[i].note
    }
}

enum MusicPack {
    struct Failure: LocalizedError { var errorDescription: String? }

    private static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("strata-packs", isDirectory: true) }

    /// packs are made in a temporary folder; old ones are removed when the app starts
    static func cleanup() { try? FileManager.default.removeItem(at: root) }

    static func safe(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let t = s.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return String(t.prefix(120)).isEmpty ? "Music Pack" : String(t.prefix(120))
    }

    static func build(_ songs: [Song], title: String, format: ExportFormat) async throws -> URL {
        let fm = FileManager.default
        let work = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = safe(title)
        let folder = work.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var tracks: [[String: Any]] = []
        var used = Set<String>()
        for (i, s) in songs.enumerated() {
            var base = safe("\(s.shownArtist) - \(s.title)")
            if !used.insert(base.lowercased()).inserted { base += " (\(i + 1))" }
            let ext = format == .original ? s.ext : format.ext
            let file = "\(base).\(ext)"
            do {
                try await Exporter.export(s, as: format, to: folder.appendingPathComponent(file)) { _ in }
                tracks.append(["file": file, "title": s.title, "artist": s.shownArtist, "album": s.album, "track": s.track, "duration": s.duration])
            } catch { continue }
        }
        if tracks.isEmpty { throw Failure(errorDescription: "None of these songs could be added to the pack") }
        let manifest: [String: Any] = ["pack": name, "app": "Strata Music", "format": format.rawValue, "created": ISO8601DateFormatter().string(from: Date()), "tracks": tracks]
        if let d = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: folder.appendingPathComponent("pack.json")) }
        let zip = work.appendingPathComponent("\(name).zip")
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
            try p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 { throw Failure(errorDescription: "The pack couldn't be zipped") }
        }.value
        return zip
    }
}
