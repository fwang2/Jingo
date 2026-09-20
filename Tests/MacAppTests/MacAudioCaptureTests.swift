import XCTest

final class MacAudioCaptureTests: XCTestCase {
  func testTimelineBufferPlacesSamplesAtTheirFrameOffset() {
    var buffer = MacAudioTimelineBuffer()

    buffer.append([0.25, 0.5], at: 2)

    // swiftlint:disable:next xctassertnodifference_preferred
    XCTAssertEqual(buffer.take(range: 0 ..< 5), [0, 0, 0.25, 0.5, 0])
  }

  func testTimelineBufferOverwritesOverlappingFrames() {
    var buffer = MacAudioTimelineBuffer()
    buffer.append([0.1, 0.2, 0.3], at: 0)

    buffer.append([0.8, 0.9], at: 1)

    // swiftlint:disable:next xctassertnodifference_preferred
    XCTAssertEqual(buffer.take(range: 0 ..< 3), [0.1, 0.8, 0.9])
  }

  func testTimelineBufferDropsSamplesThatArriveAfterTheirFramesWereConsumed() {
    var buffer = MacAudioTimelineBuffer()
    _ = buffer.take(range: 0 ..< 4)

    buffer.append([0.2, 0.4, 0.6], at: 2)

    // swiftlint:disable:next xctassertnodifference_preferred
    XCTAssertEqual(buffer.take(range: 4 ..< 6), [0.6, 0])
  }

  func testAudioSourceModesSelectExpectedInputs() {
    XCTAssertTrue(MacAudioSourceMode.automatic.includesMicrophone)
    XCTAssertFalse(MacAudioSourceMode.automatic.includesMeetingAudio)
    XCTAssertTrue(MacAudioSourceMode.microphone.includesMicrophone)
    XCTAssertFalse(MacAudioSourceMode.microphone.includesMeetingAudio)
    XCTAssertFalse(MacAudioSourceMode.meetingAudio.includesMicrophone)
    XCTAssertTrue(MacAudioSourceMode.meetingAudio.includesMeetingAudio)
    XCTAssertTrue(MacAudioSourceMode.meetingAndMicrophone.includesMicrophone)
    XCTAssertTrue(MacAudioSourceMode.meetingAndMicrophone.includesMeetingAudio)
  }

  func testAutomaticAudioSourceModeResolvesForMeetingPresence() {
    // swiftlint:disable xctassertnodifference_preferred
    XCTAssertEqual(
      MacAudioSourceMode.automatic.resolved(detectedMeeting: true),
      .meetingAndMicrophone
    )
    XCTAssertEqual(
      MacAudioSourceMode.automatic.resolved(detectedMeeting: false),
      .microphone
    )
    XCTAssertEqual(
      MacAudioSourceMode.meetingAudio.resolved(detectedMeeting: false),
      .meetingAudio
    )
    // swiftlint:enable xctassertnodifference_preferred
  }
}
