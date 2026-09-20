import CoreGraphics
import XCTest

final class MacMeetingDetectorTests: XCTestCase {
  func testIdentifiesSupportedMeetingApplications() {
    // swiftlint:disable xctassertnodifference_preferred
    XCTAssertEqual(
      MacMeetingProvider.identify(bundleIdentifier: "us.zoom.xos", applicationName: nil),
      .zoom
    )
    XCTAssertEqual(
      MacMeetingProvider.identify(bundleIdentifier: "com.microsoft.teams2", applicationName: nil),
      .teams
    )
    XCTAssertNil(
      MacMeetingProvider.identify(bundleIdentifier: "com.apple.FaceTime", applicationName: nil)
    )
    // swiftlint:enable xctassertnodifference_preferred
  }

  func testRecognizesMeetingWindowsAndRejectsMainWindows() {
    let meetingFrame = CGRect(x: 0, y: 0, width: 900, height: 700)

    XCTAssertTrue(MacMeetingProvider.zoom.isLikelyMeetingWindow(
      title: "Zoom Meeting",
      frame: meetingFrame
    ))
    XCTAssertFalse(MacMeetingProvider.zoom.isLikelyMeetingWindow(
      title: "Zoom Workplace",
      frame: meetingFrame
    ))
    XCTAssertTrue(MacMeetingProvider.teams.isLikelyMeetingWindow(
      title: "Project Sync Meeting | Microsoft Teams",
      frame: meetingFrame
    ))
    XCTAssertFalse(MacMeetingProvider.teams.isLikelyMeetingWindow(
      title: "Microsoft Teams",
      frame: meetingFrame
    ))
  }

  func testRejectsSmallMeetingNamedWindows() {
    XCTAssertFalse(MacMeetingProvider.zoom.isLikelyMeetingWindow(
      title: "Zoom Meeting",
      frame: CGRect(x: 0, y: 0, width: 200, height: 100)
    ))
  }
}
