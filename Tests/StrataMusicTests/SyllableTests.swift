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
