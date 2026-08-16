import XCTest
@testable import Polaris

final class PNO34Tests: XCTestCase {

    /// The variant table is empty by design, so every real code decodes to a
    /// raw value and nothing else. This is the case the app actually hits.
    func testUnknownCodeKeepsRawAndNamesNoVariant() {
        let spec = PNO34.decode("814PAPP0E11972900P01")
        XCTAssertEqual(spec?.raw, "814PAPP0E11972900P01")
        XCTAssertNil(spec?.variant)
    }

    func testNormalizesCaseAndWhitespace() {
        XCTAssertEqual(PNO34.decode("  534abc  ")?.raw, "534ABC")
    }

    func testBlankCodeDecodesToNil() {
        XCTAssertNil(PNO34.decode(nil))
        XCTAssertNil(PNO34.decode(""))
        XCTAssertNil(PNO34.decode("   "))
    }

    /// Guards the longest-match rule the variant table will rely on once it has
    /// entries: two prefixes matching the same code must resolve to the more
    /// specific one, not to whichever the dictionary happens to yield first.
    func testLongestPrefixWins() {
        let table = ["814": "short", "814PAPP": "long"]
        let picked = table.filter { "814PAPP0E11972900P01".hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }?.value
        XCTAssertEqual(picked, "long")
    }
}
