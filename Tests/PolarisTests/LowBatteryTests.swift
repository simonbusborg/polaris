import XCTest
@testable import Polaris

/// The reminder's whole value is that it fires once, at the right moment.
/// Every failure here is one a user would describe as "it nagged me all
/// night" or "it never told me".
final class LowBatteryTests: XCTestCase {

    private func evaluate(_ percentage: Double,
                          charging: Bool = false,
                          threshold: Int = 20,
                          warned: Bool = false) -> LowBatteryWatch.Outcome {
        LowBatteryWatch.evaluate(percentage: percentage,
                                 isCharging: charging,
                                 threshold: threshold,
                                 warned: warned)
    }

    func testFiresOnTheDownwardCrossing() {
        let outcome = evaluate(19.4)
        XCTAssertTrue(outcome.notify)
        XCTAssertTrue(outcome.warned)
    }

    func testFiresExactlyOnTheThreshold() {
        XCTAssertTrue(evaluate(20).notify)
    }

    func testStaysQuietAboveTheThreshold() {
        XCTAssertFalse(evaluate(21).notify)
    }

    func testDoesNotRepeatWhileStillLow() {
        let outcome = evaluate(12, warned: true)
        XCTAssertFalse(outcome.notify)
        XCTAssertTrue(outcome.warned, "still low, so still spent")
    }

    /// The case that makes the flag worth persisting: after a relaunch there
    /// is no previous reading to compare against, only the stored flag.
    func testStaysQuietAfterRelaunchWhenAlreadyWarned() {
        XCTAssertFalse(evaluate(11, warned: true).notify)
    }

    func testStaysQuietWhileCharging() {
        let outcome = evaluate(8, charging: true)
        XCTAssertFalse(outcome.notify)
        XCTAssertFalse(outcome.warned, "plugging in must not spend the reminder")
    }

    func testHoveringOnTheLineDoesNotRearm() {
        // Back above the threshold, but inside the margin.
        let outcome = evaluate(21, warned: true)
        XCTAssertFalse(outcome.notify)
        XCTAssertTrue(outcome.warned)
    }

    func testRearmsOnceWellAboveTheThreshold() {
        let rearmed = evaluate(40, warned: true)
        XCTAssertFalse(rearmed.notify)
        XCTAssertFalse(rearmed.warned)
        // ...and the next discharge warns again.
        XCTAssertTrue(evaluate(19, warned: rearmed.warned).notify)
    }

    func testHonoursACustomThreshold() {
        XCTAssertFalse(evaluate(30, threshold: 25).notify)
        XCTAssertTrue(evaluate(24, threshold: 25).notify)
    }

    func testDefaultThresholdIsOffered() {
        XCTAssertTrue(LowBatteryWatch.thresholds.contains(LowBatteryWatch.defaultThreshold))
    }
}
