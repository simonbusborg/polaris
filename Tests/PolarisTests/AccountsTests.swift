//
//  AccountsTests.swift
//  PolarisTests
//
//  The multi-account bookkeeping is the part that can quietly strand a
//  user: forget which account owns a VIN and switching cars signs them
//  into the wrong one, or nothing at all. These cover that mapping.
//
//  They write to the real UserDefaults, so each test cleans up after
//  itself rather than leaving a fake account behind in the app.
//

import XCTest
@testable import Polaris

final class AccountsTests: XCTestCase {

    private let a = "one@example.com"
    private let b = "two@example.com"

    override func setUp() {
        super.setUp()
        wipe()
    }

    override func tearDown() {
        wipe()
        super.tearDown()
    }

    private func wipe() {
        for email in Accounts.all { UserDefaults.standard.removeObject(forKey: "polestar_cars_\(email)") }
        Accounts.all = []
        Preferences.email = ""
        Preferences.vin = ""
    }

    func testAddIgnoresDuplicatesAndBlanks() {
        Accounts.add(a)
        Accounts.add(a)
        Accounts.add("")
        XCTAssertEqual(Accounts.all, [a])
    }

    func testCarsRoundTripPerAccount() {
        Accounts.add(a)
        Accounts.add(b)
        Accounts.setCars([CarSummary(vin: "VIN1", title: "Polestar 4")], for: a)
        Accounts.setCars([CarSummary(vin: "VIN2", title: "Polestar 2")], for: b)

        XCTAssertEqual(Accounts.cars(for: a).map(\.vin), ["VIN1"])
        XCTAssertEqual(Accounts.allCars.map(\.vin), ["VIN1", "VIN2"])
    }

    func testOwnerOfVin() {
        Accounts.add(a)
        Accounts.add(b)
        Accounts.setCars([CarSummary(vin: "VIN1", title: "Polestar 4")], for: a)
        Accounts.setCars([CarSummary(vin: "VIN2", title: "Polestar 2")], for: b)

        XCTAssertEqual(Accounts.owner(ofVin: "VIN2"), b)
        XCTAssertNil(Accounts.owner(ofVin: "NOPE"))
    }

    /// Removing the account you're on has to leave the app pointing at the
    /// other car, not at an address that no longer exists.
    func testRemovingActiveAccountFallsBackToTheOther() {
        Accounts.add(a)
        Accounts.add(b)
        Accounts.setCars([CarSummary(vin: "VIN1", title: "Polestar 4")], for: a)
        Accounts.setCars([CarSummary(vin: "VIN2", title: "Polestar 2")], for: b)
        Preferences.email = b
        Preferences.vin = "VIN2"

        Accounts.remove(b)

        XCTAssertEqual(Accounts.all, [a])
        XCTAssertEqual(Preferences.email, a)
        XCTAssertEqual(Preferences.vin, "VIN1")
        XCTAssertTrue(Accounts.cars(for: b).isEmpty)
    }

    func testMigrationAdoptsTheSingleStoredAccount() {
        Preferences.email = a
        Accounts.migrateSingleAccount()
        XCTAssertEqual(Accounts.all, [a])

        // Second launch: the list is no longer empty, so nothing happens.
        Preferences.email = b
        Accounts.migrateSingleAccount()
        XCTAssertEqual(Accounts.all, [a])
    }
}
