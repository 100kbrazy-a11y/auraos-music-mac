import XCTest
import SwiftUI
@testable import StrataMusic

@MainActor
final class CoreTests: XCTestCase {
    func testLineSyncedLyrics() throws {
        let l = try XCTUnwrap(LyricsStore.parse("[ar:Someone]\n[00:01.50] Hello there world\n[00:05.00] Bye\n[00:03.00][00:09.00] Chorus"))
        XCTAssertEqual(l.map { $0.text }, ["Hello there world", "Chorus", "Bye", "Chorus"])
        XCTAssertEqual(l[0].time, 1.5, accuracy: 0.001)
        XCTAssertEqual(l[3].time, 9.0, accuracy: 0.001)
        // no word tags: words are estimated, in order, inside the line
        XCTAssertEqual(l[0].words.count, 3)
        XCTAssertEqual(l[0].words.map { $0.start }, l[0].words.map { $0.start }.sorted())
        XCTAssertGreaterThanOrEqual(l[0].words[0].start, 1.5)
        XCTAssertLessThan(l[0].words[2].start, 3.0)
    }

    func testEnhancedLyricsKeepTheirWordTimes() throws {
        let l = try XCTUnwrap(LyricsStore.parse("[00:10.00] <00:10.00>Hello <00:10.60>big <00:11.20>world"))
        XCTAssertEqual(l.count, 1)
        XCTAssertEqual(l[0].text, "Hello big world")
        XCTAssertEqual(l[0].words.map { $0.start }, [10.0, 10.6, 11.2])
    }

    func testNothingToParse() { XCTAssertNil(LyricsStore.parse("just some words\nwithout stamps")) }

    func testPrimaryArtist() {
        XCTAssertEqual(primaryArtist("Drake feat. Rihanna"), "Drake")
        XCTAssertEqual(primaryArtist("Simon & Garfunkel"), "Simon")
        XCTAssertEqual(primaryArtist("Solo"), "Solo")
    }

    func testTimeFormat() {
        XCTAssertEqual(fmtTime(0), "0:00")
        XCTAssertEqual(fmtTime(65), "1:05")
        XCTAssertEqual(fmtTime(3599.6), "60:00")
        XCTAssertEqual(fmtTime(-3), "0:00")
    }

    func testHashIsStable() {
        XCTAssertEqual(fnv(Data("abc".utf8)), fnv(Data("abc".utf8)))
        XCTAssertNotEqual(fnv(Data("abc".utf8)), fnv(Data("abd".utf8)))
        XCTAssertEqual(fnv(Data()), "cbf29ce484222325")
    }

    func testVersionOrder() {
        XCTAssertTrue(Updater.newer("1.10.0", than: "1.9.0"))
        XCTAssertTrue(Updater.newer("2.0.0", than: "1.99.9"))
        XCTAssertFalse(Updater.newer("1.2.0", than: "1.2.0"))
        XCTAssertFalse(Updater.newer("1.2", than: "1.2.0"))
        XCTAssertTrue(Updater.newer("1.2.1", than: "1.2"))
    }

    func testSeasons() {
        var c = DateComponents(); c.year = 2026; c.day = 15
        c.month = 10; XCTAssertEqual(Season.forDate(Calendar.current.date(from: c)!), .autumn)
        c.month = 1; XCTAssertEqual(Season.forDate(Calendar.current.date(from: c)!), .winter)
        c.month = 4; XCTAssertEqual(Season.forDate(Calendar.current.date(from: c)!), .spring)
        c.month = 7; XCTAssertEqual(Season.forDate(Calendar.current.date(from: c)!), .off)
        // the old on/off leaves switch still decides until a season is chosen
        XCTAssertEqual(Season.resolve("", legacyLeaves: true), .autumn)
        XCTAssertNil(Season.resolve("", legacyLeaves: false))
        XCTAssertEqual(Season.resolve("winter", legacyLeaves: false), .winter)
        XCTAssertNil(Season.resolve("off", legacyLeaves: true))
    }

    func testColourHex() {
        XCTAssertEqual(Color(hex: "#9E80FF").hexString, "#9E80FF")
        XCTAssertEqual(Color(hex: "ff0000").hexString, "#FF0000")
    }

    func testLatinLettersForOtherScripts() {
        XCTAssertNil(LyricsFilter.romanize("Hello there"))
        XCTAssertNotNil(LyricsFilter.romanize("Привет мир"))
    }

    func testSyncKeepsTheLargestPlayCount() {
        XCTAssertEqual(SyncMerge.plays([3, 9, 5]), 9)
        XCTAssertEqual(SyncMerge.plays([]), 0)
    }

    func testSyncLatestLikeWins() {
        XCTAssertEqual(SyncMerge.fav([SyncFav(fav: true, at: 10), SyncFav(fav: false, at: 20)])?.fav, false)
        XCTAssertEqual(SyncMerge.fav([SyncFav(fav: false, at: 30), SyncFav(fav: true, at: 20)])?.fav, false)
        XCTAssertNil(SyncMerge.fav([]))
    }

    func testSyncPlaylistsAndDeletes() {
        let old = SyncPlaylist(keys: ["a|x"], updated: 10), new = SyncPlaylist(keys: ["a|x", "b|y"], updated: 20)
        XCTAssertEqual(SyncMerge.playlist([old, new], deleted: [])?.keys.count, 2)
        XCTAssertNil(SyncMerge.playlist([old, new], deleted: [25]))          // deleted after the last change
        XCTAssertNotNil(SyncMerge.playlist([old, new], deleted: [15]))       // changed again after it was deleted
    }

    func testSameSongSameKey() {
        XCTAssertEqual(SyncMerge.key(title: "  Café  Del Mar ", artist: "Energy 52 feat. X"), SyncMerge.key(title: "cafe del mar", artist: "energy 52"))
        XCTAssertNotEqual(SyncMerge.key(title: "a", artist: "b"), SyncMerge.key(title: "a", artist: "c"))
    }
}
