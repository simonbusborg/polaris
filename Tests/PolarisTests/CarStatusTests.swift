import XCTest
@testable import Polaris

final class CarStatusTests: XCTestCase {

    private let home = CarLocation(latitude: 55.6761, longitude: 12.5683, heading: nil, reportedAt: nil)

    func testDistanceIsRoughlyRight() {
        // About 100 m north of home.
        let near = CarLocation(latitude: 55.6770, longitude: 12.5683, heading: nil, reportedAt: nil)
        XCTAssertEqual(near.distance(to: home), 100, accuracy: 5)
        // Aarhus, give or take.
        let far = CarLocation(latitude: 56.1629, longitude: 10.2039, heading: nil, reportedAt: nil)
        XCTAssertEqual(far.distance(to: home) / 1000, 157, accuracy: 3)
    }

    func testUsageModeDecidesInUse() {
        XCTAssertEqual(UsageMode.isInUse("DRIVING"), true)
        XCTAssertEqual(UsageMode.isInUse("ENGINE_ON"), true)
        XCTAssertEqual(UsageMode.isInUse("INACTIVE"), false)
        XCTAssertEqual(UsageMode.isInUse("ACTIVE"), false)
        XCTAssertNil(UsageMode.isInUse(nil))
        XCTAssertNil(UsageMode.isInUse("SOMETHING_NEW"))
    }

    // MARK: HomeWatch

    private let idle = HomeWatch.State(unpluggedSince: nil, warned: false)
    private let t0 = Date(timeIntervalSince1970: 1_789_741_000)

    func testArrivalStartsTheClockWithoutFiring() {
        let out = HomeWatch.evaluate(atHome: true, pluggedIn: false, inUse: false, state: idle, now: t0)
        XCTAssertFalse(out.notify)
        XCTAssertEqual(out.state.unpluggedSince, t0)
        XCTAssertFalse(out.state.warned)
    }

    func testFiresOnceAfterTheGracePeriod() {
        let waiting = HomeWatch.State(unpluggedSince: t0, warned: false)
        let soon = HomeWatch.evaluate(atHome: true, pluggedIn: false, inUse: false,
                                      state: waiting, now: t0.addingTimeInterval(HomeWatch.grace - 1))
        XCTAssertFalse(soon.notify)
        let due = HomeWatch.evaluate(atHome: true, pluggedIn: false, inUse: false,
                                     state: waiting, now: t0.addingTimeInterval(HomeWatch.grace))
        XCTAssertTrue(due.notify)
        XCTAssertTrue(due.state.warned)
        let again = HomeWatch.evaluate(atHome: true, pluggedIn: false, inUse: false,
                                       state: due.state, now: t0.addingTimeInterval(HomeWatch.grace * 3))
        XCTAssertFalse(again.notify)
    }

    func testPluggingInOrLeavingResets() {
        let warned = HomeWatch.State(unpluggedSince: t0, warned: true)
        XCTAssertEqual(HomeWatch.evaluate(atHome: true, pluggedIn: true, inUse: false,
                                          state: warned, now: t0).state, idle)
        XCTAssertEqual(HomeWatch.evaluate(atHome: false, pluggedIn: false, inUse: false,
                                          state: warned, now: t0).state, idle)
        // Driving past the house is not parking at it.
        XCTAssertEqual(HomeWatch.evaluate(atHome: true, pluggedIn: false, inUse: true,
                                          state: warned, now: t0).state, idle)
    }

    func testUnknownsStaySilent() {
        XCTAssertFalse(HomeWatch.evaluate(atHome: nil, pluggedIn: false, inUse: false, state: idle, now: t0).notify)
        XCTAssertFalse(HomeWatch.evaluate(atHome: true, pluggedIn: nil, inUse: false, state: idle, now: t0).notify)
    }

    // MARK: OpenWatch

    private let shut = OpenWatch.State(exposedSince: nil, warned: false)

    func testLeavingItOpenStartsTheClockWithoutFiring() {
        let out = OpenWatch.evaluate(exposed: true, inUse: false, state: shut, now: t0)
        XCTAssertFalse(out.notify)
        XCTAssertEqual(out.state.exposedSince, t0)
        XCTAssertFalse(out.state.warned)
    }

    func testOpenWatchFiresOnceAfterTheGracePeriod() {
        let waiting = OpenWatch.State(exposedSince: t0, warned: false)
        let soon = OpenWatch.evaluate(exposed: true, inUse: false,
                                      state: waiting, now: t0.addingTimeInterval(OpenWatch.grace - 1))
        XCTAssertFalse(soon.notify)
        let due = OpenWatch.evaluate(exposed: true, inUse: false,
                                     state: waiting, now: t0.addingTimeInterval(OpenWatch.grace))
        XCTAssertTrue(due.notify)
        XCTAssertTrue(due.state.warned)
        let again = OpenWatch.evaluate(exposed: true, inUse: false,
                                       state: due.state, now: t0.addingTimeInterval(OpenWatch.grace * 3))
        XCTAssertFalse(again.notify)
    }

    func testShuttingItOrDrivingResets() {
        let warned = OpenWatch.State(exposedSince: t0, warned: true)
        XCTAssertEqual(OpenWatch.evaluate(exposed: false, inUse: false, state: warned, now: t0).state, shut)
        // Driving off with a window down is not a reminder to stop for.
        XCTAssertEqual(OpenWatch.evaluate(exposed: true, inUse: true, state: warned, now: t0).state, shut)
    }

    // MARK: Row wording

    func testAgeSuffixOnlyWhenStale() {
        let now = Date()
        XCTAssertEqual(StatusItemController.ageSuffix(now.addingTimeInterval(-10 * 60), now: now), "")
        XCTAssertFalse(StatusItemController.ageSuffix(now.addingTimeInterval(-3 * 3600), now: now).isEmpty)
        XCTAssertEqual(StatusItemController.ageSuffix(nil, now: now), "")
    }

    func testCoordinateHemispheres() {
        let copenhagen = CarLocation(latitude: 55.6761, longitude: 12.5683, heading: nil, reportedAt: nil)
        XCTAssertEqual(StatusItemController.coordinate(copenhagen), "55.6761° N, 12.5683° E")
        let buenosAires = CarLocation(latitude: -34.6037, longitude: -58.3816, heading: nil, reportedAt: nil)
        XCTAssertEqual(StatusItemController.coordinate(buenosAires), "34.6037° S, 58.3816° W")
    }
}
