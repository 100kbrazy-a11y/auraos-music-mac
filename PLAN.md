# Strata Music for Mac: the plan

**The goal:** make the best music app on the Mac. It should feel like Apple Music built by people who love the Android Strata app. That means every Android feature, Liquid Glass done properly, playback that never stutters or gaps, and a library you can download anything into.

This file is written for whoever carries out the plan, which will usually be Claude. Work through it top to bottom. Each phase ships as its own release. Tick items off here (`- [x]`) in the same commit that does them, so the next session knows where things stand.

---

## 0. Rules for whoever runs this plan

1. **CI is the only compiler.** No Mac or Swift toolchain is available in the Claude workspace. Push to `main`, then watch the run with `gh run list --repo 100kbrazy-a11y/auraos-music-mac --limit 1`. If it fails, read the log with `gh api repos/100kbrazy-a11y/auraos-music-mac/actions/runs/<id>/logs` (or the job's steps) and fix it.
2. **Bump `release.json` before every push that changes code.** CI publishes the newest version in that file. If the version isn't bumped, CI overwrites the existing release's files (`--clobber`). To push only docs, put `[skip ci]` in the commit message.
3. **One release per phase,** or per finished chunk of a phase. Each release gets a name, like the Android ones ("The … Update"), and release notes written for the user, not developers. The update prompt in the app shows the first five bullets.
4. **Support macOS 14 and later** (raised from 13 in 2.6.0 because ONNX Runtime's Swift package needs 14). Guard newer APIs with `if #available(macOS 14/15/26, *)`. Wrap Liquid Glass in `#if compiler(>=6.2)` plus `#available(macOS 26, *)`. The fallback is always `blurPanel`.
5. **Stay in Swift 5 language mode** (tools 5.9). Strict Swift 6 concurrency would turn every file into compile errors.
6. **The `gh` CLI can't use GraphQL here.** Use `gh api repos/...` (REST) for releases, assets and runs.
7. **Never lose user data.** The library lives in `~/Library/Application Support/Strata Music/library.json`. Any change to `Song` or `Saved` must still decode old files: new fields are optional or have defaults.
8. **Nothing is tested on a real Mac until the user says so.** Say exactly that in the summary to the user. Never claim something works.

---

## Phase 1: "The Polish Update" (1.2.0)

These are the user's open requests. Each item names the cause (where it's known) and the fix.

### 1.1 Settings doesn't open
- **Cause:** `openSettingsWindow()` (Extras.swift) sends the old `showSettingsWindow:` selector. On macOS 14 and later SwiftUI ignores it. That breaks the sidebar Settings button and the "Open the Downloads page" button.
- **Fix:** on macOS 14 and later, use `SettingsLink` for the sidebar button. Where the window has to open from code, use `@Environment(\.openSettings)` (macOS 14+). Keep the selector only as the macOS 13 fallback. Bring the app forward first with `NSApp.activate(ignoringOtherApps: true)`.
- Check that ⌘, still works (the `Settings {}` scene already provides it).
- **Better:** also add a full **Settings page inside the main window** (sidebar › Settings). It holds the same sections as the Settings window (General, Look, Playback, Lyrics, Downloads, Discord, Updates), matching the Android Settings hub. The ⌘, window becomes a second entry point to the same views.

### 1.2 Leaves go behind the text and buttons
- **What's needed:** leaves behind all text and controls, but still one continuous animation, so opening the player doesn't restart them or speed them up.
- **How:** `FallingLeaves` already places leaves purely by clock time (`timeIntervalSinceReferenceDate` with a fixed seed). Two copies drawn at the same moment are identical. So:
  - **Library copy:** draw it in the window background, under the `NavigationSplitView`. For it to show through, the sidebar, `Table`, `List`s and `ScrollView`s need clear backgrounds: `.scrollContentBackground(.hidden)` and `.background(.clear)`. Remove the opaque root `.background(Color(...))` and paint that colour *under* the leaves instead.
  - **Player copy:** in `RootView`, put `AuroraBackground` and then `FallingLeaves` in a layer that **fades in with `.opacity` only, never `.move`**. `FullPlayerView` (only the content) slides above it. The player's leaves land exactly where the library's leaves are, so the hand-off is invisible.
  - Delete the current top-level `FallingLeaves().zIndex(4)` layer.
- **Check:** no leaf is ever drawn over a song title, the media bar, the pill or the lyrics.

### 1.3 The grey pill behind the search box
- **Cause:** on macOS 26 a toolbar item is already a Liquid Glass capsule. `SearchField` adds its own `Capsule().fill(Color.white.opacity(...))` on top of that.
- **Fix:** on macOS 26 and later, draw no background of our own, and remove the inner padding that makes it look like a pill inside a pill. On older macOS keep the capsule fill.
- Also widen the field when focused (240 → 320, animated). Keep it in the toolbar's trailing (`.primaryAction`) slot next to Add Music.

### 1.4 Esc closes the full-screen player
- **Cause:** `.onExitCommand` only fires when a focusable view inside the player has focus, and nothing in it does.
- **Fix:** add a hidden `Button("", action: close).keyboardShortcut(.cancelAction)` inside `FullPlayerView`, using `.opacity(0)` plus `.allowsHitTesting(false)`. Belt and braces: in `RootView`, while `showPlayer` is true, install an `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` for keyCode 53 and remove it when the player closes. Esc must still close popovers, menus and the export sheet first (the monitor ignores events while `NSApp.keyWindow?.attachedSheet != nil` or a popover is open).
- Space should still play/pause while the player is open. Check that the Playback menu shortcut still reaches it.

### 1.5 The close button's tiny hitbox
- **Cause:** the button sits in the window's 28 pt title bar strip. With the toolbar hidden, that strip still swallows clicks for window dragging. `.buttonStyle(.plain)` also only hits the glyph's pixels.
- **Fix:**
  - While the player is open: `window.styleMask.insert(.fullSizeContentView)` and `titlebarAppearsTransparent = true` (through the existing `WindowAccessor`). Undo both when it closes.
  - Make the button 44×44 with `.contentShape(Circle())`, placed below the title bar strip (top padding about 34 pt, to the right of the traffic lights).
  - Add a glass hover state: scale 1.06 and a brighter tint on `.onHover`.
  - Also let the user **drag down anywhere on the player background** to close it (a vertical `DragGesture` of more than 120 pt), the way the Android player works.

### 1.6 The media bar morphs into the player
- **Now:** the bar sits still while the player slides up over it.
- **Wanted:** as the player comes in, the bar **fades out and slides up** with it, and the reverse on close.
  - **v1:** drive one animatable value `openProgress` (0…1) with a spring. The bar gets `.opacity(1 - p)` and `.offset(y: -60 * p)`. The player gets `.offset(y: (1 - p) * height)`. Everything moves on the same spring, so it all feels like one motion.
  - **v2, the real thing (matches Android):** `matchedGeometryEffect` the bar's cover onto the player's big cover, and the title and artist onto the player's title and artist. The glass capsule grows into the full-window surface. That's the "bar becomes the full-screen window" look. Keep v1 as the fallback if v2 stutters.
- Let the user drag the bar upward to open the player.

### 1.7 Download a whole artist
- In `YtArtistView` add **"Download everything"**. It gets every album and single from `YtEngine.artist(id)`, calls `tracks(kind:"album", id:)` for each one, one at a time, and shows progress ("Reading album 3 of 14"). It drops duplicate song ids, and it drops songs whose title and artist already match something in the library. Then it queues everything in `Downloads`, in release order.
  - Ask first with a small centred card, styled like the update prompt: "Download 143 songs from 14 releases by X?" with **Not now** / **Download all**.
  - Include an "Albums only / everything" switch.
- Put a download-everything button on the **artist rows in the YouTube search results** too (the `arrow.down.circle` icon), plus right-click › "Download Artist".
- From a **library artist page**: add "Get more from YouTube Music". It finds the artist on YouTube (searching artists for the name and taking the first exact match) and opens their YouTube page.
- **Check:** cancelling halfway leaves no orphaned files, and `items` stays responsive with 500+ queued (use `List` row identity, and no `items.map` on the whole array for every progress tick: update by index and throttle progress updates to 8 per second per item).

### 1.8 General polish pass (do all of these)
- **Hover states everywhere:** rows highlight, the album grid lifts slightly, the play overlay appears on album art when hovered (the Apple Music look).
- **Album grid:** double-click plays the album. Each card shows a ▶ button in the corner on hover.
- **Song table:** the row now playing shows animated equaliser bars instead of a plain accent colour. The table gets a "♥" column and a "Plays" column (needs play counts, see 2.4). Right-click works on the whole selection everywhere.
- **Empty states and loading** look consistent: one `EmptyState(icon:title:text:button:)` view.
- **Transitions:** page changes in the sidebar crossfade (0.15 s). Remove the jumpy `.id(nav)` rebuild if it causes flashing, and reset the `NavigationPath` instead.
- **Typography:** one set of sizes in `Theme` (largeTitle 28 heavy, title 20 bold, body 13, caption 11). Replace the scattered `.system(size:)` calls.
- **Window:** remember its size and position (`.defaultSize`, `NSWindow.setFrameAutosaveName`). Opening again restores the last page and the last song (paused).
- **Media bar:** add a volume slider on hover, and a like ♥. Clicking the artist name goes to the artist page.
- **Status banner:** use the glass toast style with an icon and auto-dismiss, and let new messages replace old ones without flicker.
- **Accessibility:** labels on every icon-only button, plus a "Reduce Motion" check that turns off leaves, aurora drift and springs.

---

## Phase 2: "The Sound Update" (1.3.0), playback that beats Apple Music

### 2.1 A new audio engine: `AVAudioEngine` replaces `AVPlayer`
- `AVAudioPlayerNode` with the next file scheduled ahead of time gives true **gapless** playback, live albums included.
- **Crossfade:** 0–12 s, set in Settings › Playback, using two player nodes and a mixer volume ramp. It is turned off automatically between consecutive tracks of the same album.
- **Equaliser:** `AVAudioUnitEQ`, 10 bands, with presets (Flat, Bass Boost, Vocal, Treble, Loudness, Late Night) and a custom curve editor drawn as a draggable line.
- **Volume levelling:** read ReplayGain/iTunNORM tags when they exist. Otherwise measure loudness once (an EBU R128-style RMS pass in the background) and store it per song.
- **Visualiser feed:** a tap on the main mixer feeds an FFT (`vDSP`). The player can show bars or a glow that reacts to the music, which links to the aurora.
- **Speed and pitch** (`AVAudioUnitTimePitch`): 0.5–2× from the player's ⋯ menu.
- Keep the same `Player` public API (`play`, `queue`, `seek`…) so the views don't change. Keep `AVPlayer` code behind a flag for one release as a fallback.

### 2.2 Play Opus, Ogg and WebM (Android packs and old downloads)
- Core Audio decodes Opus inside **CAF**. Ogg-Opus can be remuxed into CAF without re-encoding (the Android side already has a webm→ogg remuxer, `WebmOpus.toOgg`, to port from).
- **Try first:** `AVAudioFile` reading an Opus CAF.
- **If that fails:** decode with a bundled libopus (built in CI as a static library through SwiftPM `.binaryTarget` or a C target) into PCM for the new engine.
- Remove "Songs this Mac can't play yet" from Settings once this works.

### 2.3 AirPlay and output picker
- `AVRoutePickerView` goes in the player and the media bar. Add a menu to pick the output device (Core Audio device list) without opening System Settings.

### 2.4 Listening history
- Store play counts, last played and skips in `library.json` (new optional fields).
- These feed Recently Played, Most Played, smart playlists (3.2) and "Replay" (4.3).

---

## Phase 3: "The Library Update" (1.4.0)

- **3.1 Edit Info window.** Edit title, artist, album, album artist, track, year and genre. Choose a cover from a file, paste one, or **"Find cover online"** (iTunes Search API, the Android app does the same). "Look up song info" fills fields from iTunes/MusicBrainz, then asks "Use this info?" the way Android does. Write the tags into the file (M4A through a passthrough export, the way `Downloads.tag` does), not just into the library.
- **3.2 Smart playlists.** Rules on any field (artist, plays, added, liked, length…) plus a limit, updating live. Ship built-ins: Most Played, Recently Played, Never Played, Liked Songs.
- **3.3 Playlist polish.** Drag songs into a playlist in the sidebar, reorder by dragging, show a cover collage, duplicate a playlist, import and export M3U, and give it a description.
- **3.4 Watch folders.** Use FSEvents on the remembered folders, so new files appear and deleted files disappear without "Rescan".
- **3.5 Music packs.** Import Android `.opus` packs with their lyrics and offsets. Export a playlist as a pack ("Share as Music Pack…").
- **3.6 Bring your library over.** Import from Apple Music (Music › File › Library › Export Library XML) with play counts, likes and playlists. Import from the Android app (a backup file or pack).
- **3.7 Duplicates finder** and **Find missing covers** (both exist on Android).
- **3.8 Big-library speed.** It must stay smooth at 20,000 songs:
  - Move search filtering off the main thread.
  - Precompute lower-cased search keys.
  - Load covers lazily with a size-bucketed cache (already partly done).
  - Make `rebuild()` incremental.
  - Write `library.json` with debounced saves.

---

## Phase 4: "The Discovery Update" (1.5.0)

- **4.1 Home page** (the first sidebar item, like Apple Music's Home): Jump back in (recent), your top artists, albums you haven't played in a while, new releases from artists in your library (YouTube artist pages, checked weekly), and mixes.
- **4.2 Radio.** "Start Radio" on any song, album or artist uses the engine's existing `radio()` call. Songs already in the library play right away. The others download ahead in the background (two songs ahead) and play when ready. Mark radio items in Up Next.
- **4.3 Replay / Wrapped.** A yearly and monthly recap page with top songs, artists, minutes listened and a shareable image.
- **4.4 Better artist pages** for library artists: a big header photo (YouTube artist thumbnail or Wikipedia), bio, top songs from your plays, albums and singles split, and "Get more from YouTube Music".
- **4.5 Search everywhere.** The dropdown also shows YouTube results live under the library results, after typing stops for 400 ms, once the engine is warm. Return opens the full results page, and arrow keys move through the list.

---

## Phase 5: "The Mac Update" (1.6.0), things only a Mac app can do

- **5.1 Menu bar player** (`MenuBarExtra`): cover, title, transport, a seek bar, the like button, and Up Next. It can be turned off.
- **5.2 Mini player window.** Floating, always on top (optional), glass, resizable from a compact strip up to a square cover. Toggle it with ⌥⌘M.
- **5.3 Dock menu** with play/pause, next and like. **Notifications** on song change (optional).
- **5.4 Keyboard first.** Arrow keys move through lists, Return plays, ⌘L likes, ⌘U opens Up Next, ⌘J jumps to the current song, and typing in a list jumps to that title. A shortcuts sheet (⌘/) lists them all.
- **5.5 Full Screen (green button) mode.** It goes straight to the player, and the lyrics page becomes "karaoke on the TV".
- **5.6 Shortcuts / App Intents** (play, pause, play playlist, like current song), plus **widgets**. *These need an Xcode project or extension targets that SwiftPM can't build. Move the build to an `xcodeproj` generated in CI by XcodeGen (`project.yml`) when this phase starts, and keep `swift build` working until then.*

---

## Phase 6: "The Lyrics Update" (1.7.0)

- **Word-by-word lyrics:** each word lights up as it's sung, using enhanced LRC `<mm:ss.xx>` word tags when present. Otherwise Android's `ForcedAligner` approach estimates per-word timing.
- Fix the **lyric sync offset per song** (±, saved), importing your own `.lrc`, marking "this song has no lyrics", and the **censored words** option. All of these are Android features.
- **Translation and romanisation** for non-English lyrics (using the on-device Translation framework on macOS 15 and later when it's available).
- **Lyrics share card:** pick lines and export an image with the cover colours.
- **Lyrics in the menu bar player** and a floating "desktop lyrics" strip.

---

## Phase 7: "The Look Update" (1.8.0), customisation like Android

Port the Android Customize screen, keeping its groups.

- **Accent and colours:** from the cover or fixed. Choose the background: aurora, blurred cover, plain or animated gradient.
- **Glass:** strength and tint on macOS 26. Corner radius.
- **Player:** order of the pages, which buttons show, cover size and style, and shadow.
- **Media bar:** compact or tall, and which buttons it shows.
- **Lists:** cover size in lists and library layout (table or list).
- **Seasons:** turn the leaves into a seasonal effects system with Autumn leaves (now), Winter snow, Spring petals and Off. "Automatic" follows the date. They share the clock-based, never-in-front-of-text rule from 1.2.
- **App icon variants** through `NSApp.applicationIconImage` plus the Dock tile.

---

## Phase 8: "The Solid Update" (1.9.0 → 2.0)

- **Tests:** a `StrataCore` library target split out of the app (Library, parsing, version compare, LRC parsing, smart-playlist rules, file naming), with `swift test` in CI.
- **Crash and error reporting:** on start, detect that the last run crashed ("Strata Music crashed last time", as on Android), offer to save a diagnostics file, and keep an engine log viewer in Settings › Advanced.
- **Engine health:** a "Test YouTube" button in Settings that runs search plus a 1-song address lookup and reports which step failed. After 3 failures in a row the engine resets itself automatically (already the case for downloads; apply it to search too).
- **Notarization:** once the user has an Apple Developer ID, add the `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`, `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD` secrets. The workflow already uses them, and the Gatekeeper warning disappears.
- **Sync with Android (2.0 headline):** likes, playlists and play counts sync through a folder the user picks (iCloud Drive, Dropbox, Syncthing…) as one small JSON file per device that gets merged. No server.

---

## Questions for the user before Phase 2 starts
1. Should the Home page (4.1) become the default first page, instead of Songs?
2. Is crossfade wanted by default, or off by default?
3. For sync (8): is a shared folder (iCloud Drive and similar) fine, or should it be something else?
4. Any Android feature you use daily that isn't listed here?

---

## Progress
- [x] 1.0.x: library, player, lyrics, Discord, export, updater, icon, installer window
- [x] 1.1.0: YouTube search and downloads, search dropdown, queue, sleep timer, Recently Added
- [x] 1.2.0: Phase 1, Polish (Esc, close button, bar and player motion, leaves behind the text, search pill, "Download everything" for an artist). Skipped: the shared-element cover morph (v2) and drag-up-to-open.
- [x] 1.3.0: Phase 2, Sound (Opus decode, Enhanced engine: gapless, crossfade, EQ, speed; play counts). Not done: ReplayGain / volume levelling, the visualizer, the output-device picker.
- [x] 1.4.0: Phase 3, Library (Edit Info, smart playlists, M3U, import from Music, folder watching, duplicates, find covers). Not done: drag and drop into playlists, collage covers, big-library speed work beyond debounced saves.
- [x] 1.5.0: Phase 4, Discovery (Home, Radio, Replay, artist pages, YouTube results in search).
- [x] 1.6.0: Phase 5, Mac (menu bar player, mini player, Dock menu, notifications, shortcuts and the ⌘/ sheet, full screen opens the player). Not done: App Intents / Shortcuts and widgets (they need an Xcode project), "karaoke on the TV" lyrics in full screen.
- [x] 1.7.0: Phase 6, Lyrics (word by word, offset, import, no-lyrics mark, censor, romanise, translate on macOS 15+, share card, desktop lyrics, lyric in the menu bar).
- [x] 1.8.0: Phase 7, Look (accent, backgrounds, glass tint and radius, player and bar options, list cover size, seasons). Not done: page order, library layout (list vs table), app icon variants.
- [x] 1.9.0: Phase 8, Solid (Test YouTube, engine log, crash detection and diagnostics, engine auto-reset for search, unit tests in CI).
- [x] 2.0.0: Sync through a shared folder (likes, playlists, play counts). Smart playlists don't sync yet. Not done: moving the code into a `StrataCore` library target, notarization (needs a Developer ID).
- [x] 2.1.0: freeze fixes (saving, grouping, sorting, cover decoding and missing-file checks moved off the main thread), Downloads counters in the sidebar, Rich Presence on by default with a status line and Test button, stall log.
- [x] 2.2.0: drag and drop: onto playlists, a song out as its file, several songs / an album / a playlist out as a music pack (title and format asked on drop).
- [x] 2.3.0: performance pass, volume levelling, visualizer, output device picker, page order, list layout, Dock icon variants, strata:// links. Not done: real App Intents / Siri and widgets (need an Xcode project, an app group and a signing identity).

Nothing in 1.2.0 to 2.3.0 has been run by a person on a real Mac yet. CI builds it, runs 14 unit tests, and starts the app and checks that it stays up for 8 seconds. The YouTube engine (BotGuard, the hidden web view), the Enhanced engine, Opus decoding, the menu bar and mini player, the Translation framework, sync and the notification attachments are all untested in real use.
