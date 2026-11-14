import XCTest
@testable import LautliApp

final class AppUpdaterTests: XCTestCase {
    func testUpdaterNeedsBothKeyAndHttpsFeed() {
        let feed = "https://github.com/ameetmadan/lautli/releases/latest/download/appcast.xml"
        XCTAssertTrue(AppUpdater.isConfigured(info: ["SUPublicEDKey": "abc=", "SUFeedURL": feed]))
        XCTAssertFalse(AppUpdater.isConfigured(info: nil))
        XCTAssertFalse(AppUpdater.isConfigured(info: ["SUFeedURL": feed]))
        XCTAssertFalse(AppUpdater.isConfigured(info: ["SUPublicEDKey": " ", "SUFeedURL": feed]))
        XCTAssertFalse(AppUpdater.isConfigured(info: ["SUPublicEDKey": "abc="]))
        XCTAssertFalse(AppUpdater.isConfigured(info: ["SUPublicEDKey": "abc=", "SUFeedURL": "http://example.com/appcast.xml"]))
    }

    @MainActor
    func testUnstampedBuildsNeverStartTheUpdater() {
        XCTAssertFalse(AppUpdater(info: [:]).isAvailable)
    }
}
