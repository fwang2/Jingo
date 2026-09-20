import AudioProcessing
import Common
import Foundation
import XCTest

// MARK: - SpeakerDiarizationDeviceTests

final class SpeakerDiarizationDeviceTests: XCTestCase {
  func testTranscribesAlignsAndIdentifiesSpeakersOnDevice() async throws {
    #if targetEnvironment(simulator)
      throw XCTSkip("Qwen and FluidAudio integration inference must run on a physical Apple Silicon iOS device.")
    #else
      let bundle = Bundle(for: type(of: self))
      let audioURL = try XCTUnwrap(bundle.url(forResource: "example", withExtension: "wav"))
      let client = RecordingTranscriptionStream.liveValue

      try await client.loadModel(Model.defaultModelName) { _ in }
      let result = try await client.transcribeAudioFile(audioURL) { _, _ in true }

      XCTAssertFalse(result.text.isEmpty)
      XCTAssertFalse(result.segments.isEmpty)
      XCTAssertTrue(result.segments.contains { $0.speaker != nil })
      XCTAssertTrue(result.segments.contains { !$0.words.isEmpty })

      let expectedText = "In the heart of a bustling city"
      XCTAssertTrue(
        result.text.lowercased().contains(expectedText.lowercased()),
        "Expected \(expectedText), got: \(result.text)"
      )

      for segment in result.segments {
        XCTAssertGreaterThan(segment.endTimeMS, segment.startTimeMS)
        for word in segment.words {
          XCTAssertGreaterThan(word.endTimeMS, word.startTimeMS)
        }
      }
    #endif
  }

  func testDiarizesAudioFileOnDevice() async throws {
    #if targetEnvironment(simulator)
      throw XCTSkip("FluidAudio integration inference must run on a physical Apple Silicon iOS device.")
    #else
      let bundle = Bundle(for: type(of: self))
      let audioURL = try XCTUnwrap(bundle.url(forResource: "example", withExtension: "wav"))
      let client = SpeakerDiarizationClient.liveValue
      let progressRecorder = ProgressRecorder()

      try await client.prepareModels()
      try await client.prepareModels()

      let result = try await client.diarize(audioURL) { progress in
        progressRecorder.record(progress)
      }

      XCTAssertFalse(result.segments.isEmpty)
      XCTAssertGreaterThan(result.speakerCount, 0)
      XCTAssertEqual(progressRecorder.lastValue, 1, accuracy: 0.0001)

      for segment in result.segments {
        XCTAssertFalse(segment.speakerID.isEmpty)
        XCTAssertGreaterThanOrEqual(segment.startTimeMS, 0)
        XCTAssertGreaterThan(segment.endTimeMS, segment.startTimeMS)
        XCTAssertTrue(segment.qualityScore.isFinite)
      }

      XCTAssertEqual(
        result.segments.map(\.startTimeMS),
        result.segments.map(\.startTimeMS).sorted()
      )
    #endif
  }
}

// MARK: - ProgressRecorder

private final class ProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Double] = []

  var lastValue: Double {
    lock.withLock { values.last ?? 0 }
  }

  func record(_ value: Double) {
    lock.withLock {
      values.append(value)
    }
  }
}
