import SwiftUI
import AppKit

/// Up Next: the queue as a list you can jump around in
struct QueueView: View {
    @EnvironmentObject var player: Player
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Up Next").font(.system(size: 15, weight: .bold))
                Spacer()
                if player.queue.count > player.index + 1 { Button("Clear") { player.clearUpNext() }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if player.queue.isEmpty {
                Text("Nothing is queued").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(player.queue.enumerated()), id: \.offset) { i, s in
                                HStack(spacing: 10) {
                                    CoverView(song: s, size: 34, radius: 6)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(s.title).font(.system(size: 12.5, weight: i == player.index ? .bold : .regular)).lineLimit(1).foregroundStyle(i == player.index ? player.accent : Color.primary)
                                        Text(s.shownArtist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if i == player.index { Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(player.accent) }
                                    else { Button { player.removeFromQueue(i) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Remove from the queue") }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 5)
                                .background(i == player.index ? Color.white.opacity(0.07) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { player.jump(to: i) }
                                .id(i)
                            }
                        }
                    }
                    .onAppear { proxy.scrollTo(player.index, anchor: .top) }
                }
            }
        }
        .frame(width: 340, height: 420)
    }
}

struct QueueButton: View {
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: { Image(systemName: "list.bullet") }
            .buttonStyle(.plain).help("Up Next")
            .popover(isPresented: $show, arrowEdge: .top) { QueueView() }
    }
}

struct SleepButton: View {
    @EnvironmentObject var player: Player
    var body: some View {
        Menu {
            if player.sleepEnd != nil || player.sleepAtSongEnd {
                Button("Turn Sleep Timer Off") { player.cancelSleep() }
                Divider()
            }
            ForEach([15, 30, 45, 60, 90], id: \.self) { m in Button("In \(m) minutes") { player.sleep(minutes: m) } }
            Button("After this song") { player.sleepAfterThisSong() }
        } label: {
            Image(systemName: player.sleepEnd != nil || player.sleepAtSongEnd ? "moon.zzz.fill" : "moon.zzz")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(player.sleepAtSongEnd ? "Stops after this song" : (player.sleepEnd.map { "Stops at " + $0.formatted(date: .omitted, time: .shortened) } ?? "Sleep timer"))
    }
}

/// opens the Settings window (⌘,)
func openSettingsWindow() {
    if #available(macOS 14, *) { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
    else { NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil) }
}

/// lets a view reach its NSWindow (to hide the title while the full-screen player is up)
struct WindowAccessor: NSViewRepresentable {
    var configure: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { if let w = v.window { configure(w) } } }
}
