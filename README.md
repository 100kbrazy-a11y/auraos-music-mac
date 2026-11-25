# Strata Music for Mac

The Mac version of Strata Music: the Android app's look mixed with Apple Music's layout, in SwiftUI.
Liquid Glass on macOS 26 and later, blurred glass on macOS 12 to 15.

- Songs, Albums, Artists, Favorites, Playlists; add folders or drop songs on the window
- Full-screen player with three pages (Lyrics, Current Song, Artist) and a glass pill to switch between them
- Synced lyrics (LRCLIB or a `.lrc` next to the song), falling leaves (The Thanksgiving Update)
- Word timing: a small home-made voice finder (Sources/CVoice, plain C) picks out the singing and lines each word up with it; nothing to download
- Discord Rich Presence with the album cover, over the Discord app on the Mac (no sign-in)
- Export a song as M4A, ALAC, FLAC, WAV or AIFF; media keys and Control Centre
- Updates from GitHub releases (`mac-vX.Y.Z`)

## Install

Download the `.dmg` from Releases and drag the app to Applications. It is signed ad hoc, not notarized, so the first
time right-click the app and choose Open (or `xattr -cr "/Applications/Strata Music.app"`).

## Build

`scripts/build_app.sh 1.0.0` builds a universal `dist/Strata Music.app`, a `.dmg` and a `.zip` (needs Xcode 15+; with Xcode 26 the Liquid Glass look is compiled in).
CI (`.github/workflows/mac.yml`) does this on every push to `main` and publishes the release named by the top entry of `release.json`.

## Not done yet

- Opus / Ogg / WebM songs (what Android music packs now contain) can't be played by macOS's own decoder; they are skipped when adding music.
- YouTube search and download (the Android app uses a hidden web view for it).
- MP3 export.
