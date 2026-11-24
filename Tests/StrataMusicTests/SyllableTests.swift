import XCTest
@testable import StrataMusic

final class SyllableTests: XCTestCase {
    func testCounts() {
        XCTAssertEqual(Syllables.count("eh"), 1)
        XCTAssertEqual(Syllables.count("everyone"), 3)
        XCTAssertEqual(Syllables.count("Everybody,"), 4)
        XCTAssertEqual(Syllables.count("making"), 2)
        XCTAssertEqual(Syllables.count("couldn't"), 2)
        XCTAssertEqual(Syllables.count("don't"), 1)
        XCTAssertEqual(Syllables.count("heeeey"), 1)
        XCTAssertEqual(Syllables.count("tonight"), 2)
        XCTAssertEqual(Syllables.count("café"), 2)
        XCTAssertEqual(Syllables.count("愛してる"), 4)
    }

    func testRepeatsAreQuick() {
        XCTAssertEqual(Syllables.quick(["eh", "Eh,", "everyone"]), [1, 1, 0])
        XCTAssertEqual(Syllables.quick(["la", "la", "la", "oh"]), [1, 1, 1, 0])
        XCTAssertEqual(Syllables.quick(["hello", "there"]), [0, 0])
    }
}

@MainActor
final class WordEndTests: XCTestCase {
    func testEndTags() throws {
        // a time with no word after it says where the word before it stops being sung
        let l = try XCTUnwrap(LyricsStore.parse("[00:01.00]<00:01.00>one <00:01.50><00:03.00>two <00:03.40>\n[00:06.00]<00:06.00>three <00:06.50>four"))
        XCTAssertEqual(l[0].words.map { $0.text }, ["one ", "two "])
        XCTAssertEqual(try XCTUnwrap(l[0].words[0].end), 1.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(l[0].words[1].end), 3.4, accuracy: 0.001)
        XCTAssertEqual(l[0].sungEnd, 3.4, accuracy: 0.001)
        XCTAssertEqual(l[0].text, "one two")
        // an ordinary enhanced line has no ends
        XCTAssertNil(l[1].words[0].end)
        XCTAssertEqual(l[1].words.map { $0.text }, ["three ", "four"])
    }
}
