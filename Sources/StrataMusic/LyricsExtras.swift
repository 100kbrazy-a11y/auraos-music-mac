import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(Translation)
import Translation
#endif

/// one lyric line; the line being sung lights up word by word
struct LyricLineText: View {
    let line: LyricLine
    let t: Double          // the play position, already shifted by this song's sync offset
    let active: Bool
    var words = true

    var body: some View {
        if line.text.isEmpty {
            Text("♪")
        } else if active && words && !line.words.isEmpty {
            line.words.reduce(Text("")) { acc, w in
                acc + Text(LyricsFilter.clean(w.text)).foregroundColor(Color.white.opacity(t >= w.start ? 1 : 0.38))
            }
        } else {
            Text(LyricsFilter.clean(line.text))
        }
    }
}

// MARK: - desktop lyrics: a floating strip you can leave over other apps

struct DesktopLyricsView: View {
    @EnvironmentObject var player: Player
    @ObservedObject var store = LyricsStore.shared

    var body: some View {
        DesktopLine(store: store, clock: player.clock)
            .padding(.horizontal, 26).padding(.vertical, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black.opacity(0.55)).padding(6))
            .frame(minWidth: 380, minHeight: 90)
            .preferredColorScheme(.dark)
            .task(id: player.current?.id) { if let s = player.current { await store.ensure(s) } }
            .background(WindowAccessor { w in
                w.identifier = NSUserInterfaceItemIdentifier("StrataDesktopLyrics")
                w.title = "Desktop Lyrics"
                w.titleVisibility = .hidden
                w.titlebarAppearsTransparent = true
                w.isOpaque = false
                w.backgroundColor = .clear
                w.hasShadow = false
                w.level = .floating
                w.isMovableByWindowBackground = true
                w.collectionBehavior.insert(.canJoinAllSpaces)
                w.collectionBehavior.insert(.fullScreenAuxiliary)
                for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = true }
                _ = w.setFrameAutosaveName("StrataDesktopLyricsWindow")
            })
            .contextMenu { Button("Close") { Presence.desktopWindow?.close() } }
    }
}

private struct DesktopLine: View {
    @ObservedObject var store: LyricsStore
    @ObservedObject var clock: Clock
    @AppStorage("lyricsWords") private var wordMode = true

    var body: some View {
        let cur = store.index(at: clock.position)
        let t = clock.position + 0.2 - store.offset
        VStack(spacing: 4) {
            if store.synced, store.lines.indices.contains(cur) {
                LyricLineText(line: store.lines[cur], t: t, active: true, words: wordMode)
                    .font(.system(size: 26, weight: .heavy)).multilineTextAlignment(.center).minimumScaleFactor(0.6)
                if store.lines.indices.contains(cur + 1), !store.lines[cur + 1].text.isEmpty {
                    Text(LyricsFilter.clean(store.lines[cur + 1].text)).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
            } else {
                Text(store.synced ? "♪" : (store.loading ? "…" : "No synced lyrics")).font(.system(size: 20, weight: .bold)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// the current lyric in the menu bar player
struct MenuBarLine: View {
    @ObservedObject var store = LyricsStore.shared
    @ObservedObject var clock: Clock
    let song: Song

    var body: some View {
        let cur = store.index(at: clock.position)
        Group {
            if store.synced, store.loadedID == song.id, store.lines.indices.contains(cur), !store.lines[cur].text.isEmpty {
                Text(LyricsFilter.clean(store.lines[cur].text)).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2)
            } else { EmptyView() }
        }
        .frame(maxWidth: .infinity)
        .task(id: song.id) { await store.ensure(song) }
    }
}

// MARK: - share lines as a picture

struct LyricShareSheet: View {
    let song: Song
    let lines: [LyricLine]
    let plain: String
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var lib: Library
    @State private var picked = Set<Int>()

    private var choices: [LyricLine] {
        if !lines.isEmpty { return lines.filter { !$0.text.isEmpty } }
        return plain.split(separator: "\n").enumerated().map { LyricLine(id: $0.offset, time: 0, text: String($0.element)) }.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    private var chosen: [String] { choices.filter { picked.contains($0.id) }.prefix(6).map { LyricsFilter.clean($0.text) } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pick up to 6 lines").font(.headline).padding([.top, .horizontal], 14)
                List(choices, selection: $picked) { l in Text(LyricsFilter.clean(l.text)).lineLimit(2) }
            }
            .frame(width: 330)
            Divider()
            VStack(spacing: 14) {
                LyricCard(song: song, lines: chosen.isEmpty ? ["Pick some lines"] : chosen, accent: Covers.accent(song))
                    .frame(width: 1080, height: 1080).scaleEffect(0.28).frame(width: 302, height: 302)
                HStack {
                    Button("Save Image…") { save() }.disabled(chosen.isEmpty)
                    Button("Copy") { copy() }.disabled(chosen.isEmpty)
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(24).frame(width: 350)
        }
        .frame(height: 440)
        .preferredColorScheme(.dark)
    }

    @MainActor private func image() -> NSImage? {
        _ = Covers.image(song, maxPixel: 240)
        let r = ImageRenderer(content: LyricCard(song: song, lines: chosen, accent: Covers.accent(song)).frame(width: 1080, height: 1080))
        r.scale = 1
        return r.nsImage
    }
    @MainActor private func save() {
        guard let img = image(), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        let p = NSSavePanel(); p.allowedContentTypes = [.png]; p.nameFieldStringValue = "\(song.title) lyrics.png"
        if p.runModal() == .OK, let u = p.url { try? png.write(to: u) }
    }
    @MainActor private func copy() {
        guard let img = image() else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([img])
        lib.flash("Copied the image")
    }
}

struct LyricCard: View {
    let song: Song
    let lines: [String]
    let accent: Color
    var body: some View {
        ZStack {
            LinearGradient(colors: [accent.opacity(0.95), Color(red: 0.05, green: 0.04, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 30) {
                Spacer(minLength: 0)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(size: lines.count > 4 ? 56 : 70, weight: .heavy)).foregroundStyle(.white).lineLimit(3).minimumScaleFactor(0.6)
                }
                Spacer(minLength: 0)
                HStack(spacing: 22) {
                    CoverView(song: song, size: 120, radius: 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title).font(.system(size: 36, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                        Text(song.shownArtist).font(.system(size: 28)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    }
                    Spacer()
                }
            }
            .padding(80)
        }
    }
}

// MARK: - translation (macOS 15 and later; the languages download the first time)

extension View {
    @ViewBuilder func lyricsTranslation(store: LyricsStore, on: Bool) -> some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) { self.modifier(LyricsTranslator(store: store, on: on)) } else { self }
        #else
        self
        #endif
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
struct LyricsTranslator: ViewModifier {
    @ObservedObject var store: LyricsStore
    let on: Bool
    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(config) { session in
                let reqs = await MainActor.run { store.lines.filter { !$0.text.isEmpty }.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) } }
                guard !reqs.isEmpty else { return }
                await MainActor.run { store.translating = true }
                do {
                    let res = try await session.translations(from: reqs)
                    await MainActor.run {
                        for r in res { if let id = r.clientIdentifier.flatMap({ Int($0) }) { store.translated[id] = r.targetText } }
                        store.translating = false
                    }
                } catch {
                    await MainActor.run { store.translating = false }
                }
            }
            .onChange(of: on) { v in if v { trigger() } }
            .onChange(of: store.lines.count) { _ in if on { trigger() } }
            .onAppear { if on { trigger() } }
    }

    private func trigger() {
        if config == nil { config = TranslationSession.Configuration() } else { config?.invalidate() }
    }
}
#endif
