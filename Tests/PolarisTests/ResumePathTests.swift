//
//  ResumePathTests.swift
//  Login-form scraping is the part of the flow Polestar can break at any
//  time — these fixtures pin down what each regex is expected to match.
//

import XCTest
@testable import Polaris

final class ResumePathTests: XCTestCase {

    func testCurrentLoginPageActionQuoted() {
        let html = #"<script>var flow = { action: "/as/abc123/resume/as/authorization.ping", other: 1 };</script>"#
        XCTAssertEqual(PolestarAPI.extractResumePath(from: html),
                       "/as/abc123/resume/as/authorization.ping")
    }

    func testPingDotSuffixNotTruncated() {
        // A bare path in text — the fallback pattern must keep ".ping" intact.
        let html = "resume at /as/xY-9_z/resume/as/authorization.ping please"
        XCTAssertEqual(PolestarAPI.extractResumePath(from: html),
                       "/as/xY-9_z/resume/as/authorization.ping")
    }

    func testResumePathAssignment() {
        let html = "var resumePath = '/idp/abc/resume';"
        XCTAssertEqual(PolestarAPI.extractResumePath(from: html), "/idp/abc/resume")
    }

    func testFormActionAttribute() {
        let html = #"<form method="POST" action="/as/form99/resume"><input name="pf.username"></form>"#
        XCTAssertEqual(PolestarAPI.extractResumePath(from: html), "/as/form99/resume")
    }

    func testAbsoluteURLNotMistakenForPath() {
        // `url: "https://…"` matches the first pattern but is not a path;
        // the parser must fall through to the bare-path fallback.
        let html = #"config = { url: "https://polestarid.eu.polestar.com/x" }; go(/as/fall-back/resume)"#
        XCTAssertEqual(PolestarAPI.extractResumePath(from: html), "/as/fall-back/resume")
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(PolestarAPI.extractResumePath(from: "<html><body>Maintenance</body></html>"))
    }
}
