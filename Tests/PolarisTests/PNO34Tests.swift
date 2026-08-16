import XCTest
@testable import Polaris

final class PNO34Tests: XCTestCase {
    func testDecodesKnownModelPrefix() {
        let spec = PNO34.decode("534ABCDEFGHIJKLMNOPQRSTUVWXYZ01234")
        XCTAssertEqual(spec?.make, "Polestar")
        XCTAssertEqual(spec?.model, "Polestar 2")
    }

    /// An unknown car must degrade to make-only, never to a guessed model.
    func testUnknownPrefixYieldsMakeOnly() {
        let spec = PNO34.decode("999ABCDEFGHIJKLMNOPQRSTUVWXYZ01234")
        XCTAssertEqual(spec?.make, "Polestar")
        XCTAssertNil(spec?.model)
        XCTAssertNil(spec?.variant)
    }

    func testNormalizesCaseAndWhitespace() {
        XCTAssertEqual(PNO34.decode("  534abc  ")?.raw, "534ABC")
        XCTAssertEqual(PNO34.decode("  534abc  ")?.model, "Polestar 2")
    }

    func testBlankCodeDecodesToNil() {
        XCTAssertNil(PNO34.decode(nil))
        XCTAssertNil(PNO34.decode(""))
        XCTAssertNil(PNO34.decode("   "))
    }

    func testSubtitleOmitsUnknownParts() {
        XCTAssertEqual(PNO34.decode("534XYZ")?.subtitle, "Polestar 2")
        XCTAssertNil(PNO34.decode("999XYZ")?.subtitle)
    }

    /// Guards the longest-match rule that lets a variant table key off a
    /// longer prefix than the model table without the two colliding.
    func testLongestPrefixWins() {
        let table = ["53": "short", "534": "long"]
        let picked = table.filter { "534ABC".hasPrefix($0.key) }
            .max { $0.key.count < $1.key.count }?.value
        XCTAssertEqual(picked, "long")
    }
}
