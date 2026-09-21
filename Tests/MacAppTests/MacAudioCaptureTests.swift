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

  func testSpeechPhraseWaitsForConfiguredSilence() {
    var segmenter = MacSpeechPhraseSegmenter(configuration: .init(
      sampleRate: 100,
      speechThreshold: 0.5,
      minimumSpeechDuration: 0.2,
      silenceDuration: 0.3,
      speechPadding: 0.1,
      preRollDuration: 0.1,
      maximumPhraseDuration: 10
    ))

    XCTAssertNil(segmenter.consume(samples: Array(repeating: 0, count: 10), speechProbability: 0))
    XCTAssertNil(segmenter.consume(samples: Array(repeating: 1, count: 20), speechProbability: 0.9))
    XCTAssertNil(segmenter.consume(samples: Array(repeating: 0, count: 20), speechProbability: 0.1))
    let phrase = segmenter.consume(samples: Array(repeating: 0, count: 10), speechProbability: 0.1)

    // swiftlint:disable xctassertnodifference_preferred
    XCTAssertEqual(phrase?.startSample, 0)
    XCTAssertEqual(phrase?.endSample, 40)
    XCTAssertEqual(phrase?.samples.count, 40)
    // swiftlint:enable xctassertnodifference_preferred
  }

  func testSpeechPhraseDropsBurstsShorterThanMinimumSpeechDuration() {
    var segmenter = MacSpeechPhraseSegmenter(configuration: .init(
      sampleRate: 100,
      speechThreshold: 0.5,
      minimumSpeechDuration: 0.3,
      silenceDuration: 0.2,
      speechPadding: 0,
      preRollDuration: 0.1,
      maximumPhraseDuration: 10
    ))

    XCTAssertNil(segmenter.consume(samples: Array(repeating: 1, count: 20), speechProbability: 0.9))
    XCTAssertNil(segmenter.consume(samples: Array(repeating: 0, count: 20), speechProbability: 0.1))
  }

  func testSpeechPhraseFlushesAtMaximumDuration() {
    var segmenter = MacSpeechPhraseSegmenter(configuration: .init(
      sampleRate: 100,
      speechThreshold: 0.5,
      minimumSpeechDuration: 0.1,
      silenceDuration: 1,
      speechPadding: 0,
      preRollDuration: 0.1,
      maximumPhraseDuration: 0.3
    ))

    XCTAssertNil(segmenter.consume(samples: Array(repeating: 1, count: 20), speechProbability: 0.9))
    let phrase = segmenter.consume(samples: Array(repeating: 1, count: 10), speechProbability: 0.9)

    // swiftlint:disable:next xctassertnodifference_preferred
    XCTAssertEqual(phrase?.samples.count, 30)
  }
}
