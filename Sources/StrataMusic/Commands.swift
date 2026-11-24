import Foundation

/// strata:// links, for the Shortcuts app ("Open URL"), Raycast, Alfred, scripts and the Terminal (`open strata://pause`)
///   strata://play  pause  toggle  next  previous  like  shuffle  repeat
///   strata://play?q=some words        plays the best match in your library
///   strata://playlist?name=Road Trip  plays one of your playlists (add &shuffle=1 to shuffle it)
///   strata://volume?level=0.5         sets the volume (0 to 1)
@MainActor
enum URLCommands {
    static func handle(_ url: URL, lib: Library, player: Player) {
        let cmd = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func arg(_ n: String) -> String? { items.first { $0.name == n }?.value }
        switch cmd {
        case "play":
            if let q = arg("q"), !q.isEmpty {
                let f = q.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                if let s = lib.songs.first(where: { ($0.title + " " + $0.artist + " " + $0.album).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(f) }) { player.play(s, in: [s]) }
                else { lib.flash("Nothing matches “\(q)”") }
            } else if !player.isPlaying { player.togglePlay() }
        case "pause": if player.isPlaying { player.togglePlay() }
        case "toggle", "playpause": player.togglePlay()
        case "next": player.next()
        case "previous", "prev": player.previous()
        case "like", "favorite": if let s = player.current { lib.toggleFav(s) }
        case "shuffle": player.shuffle.toggle()
        case "repeat": player.cycleRepeat()
        case "volume": if let v = arg("level").flatMap(Float.init) { player.volume = max(0, min(1, v)) }
        case "playlist":
            if let n = arg("name"), let p = lib.playlists.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
                let songs = lib.songs(in: p)
                if !songs.isEmpty { player.playAll(songs, shuffled: arg("shuffle") == "1") }
            } else { lib.flash("No playlist with that name") }
        default: break
        }
    }
}
