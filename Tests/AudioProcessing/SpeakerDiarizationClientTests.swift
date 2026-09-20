@testable import AudioProcessing
import FluidAudio
import XCTest

// MARK: - SpeakerDiarizationClientTests

final class SpeakerDiarizationClientTests: XCTestCase {
  func testMapsValidSegmentsToMillisecondsAndSortsThem() {
    let result = SpeakerDiarizationResultMapper.map([
      TimedSpeakerSegment(
        speakerId: "S2",
        embedding: [],
        startTimeSeconds: 2.005,
        endTimeSeconds: 3.006,
        qualityScore: 0.8
      ),
      TimedSpeakerSegment(
        speakerId: "S1",
        embedding: [],
        startTimeSeconds: 0,
        endTimeSeconds: 1.2346,
        qualityScore: 0.9
      ),
    ])

    XCTAssertEqual(
      result.segments,
      [
        SpeakerDiarizationSegment(
          speakerID: "S1",
          startTimeMS: 0,
          endTimeMS: 1235,
          qualityScore: 0.9
        ),
        SpeakerDiarizationSegment(
          speakerID: "S2",
          startTimeMS: 2005,
          endTimeMS: 3006,
          qualityScore: 0.8
        ),
      ]
    )
    XCTAssertEqual(result.speakerCount, 2)
  }

  func testDropsInvalidSegments() {
    let result = SpeakerDiarizationResultMapper.map([
      TimedSpeakerSegment(
        speakerId: " ",
        embedding: [],
        startTimeSeconds: 0,
        endTimeSeconds: 1,
        qualityScore: 1
      ),
      TimedSpeakerSegment(
        speakerId: "S1",
        embedding: [],
        startTimeSeconds: -1,
        endTimeSeconds: 1,
        qualityScore: 1
      ),
      TimedSpeakerSegment(
        speakerId: "S1",
        embedding: [],
        startTimeSeconds: 1,
        endTimeSeconds: 1,
        qualityScore: 1
      ),
      TimedSpeakerSegment(
        speakerId: "S1",
        embedding: [],
        startTimeSeconds: .nan,
        endTimeSeconds: 1,
        qualityScore: 1
      ),
    ])

    XCTAssertTrue(result.segments.isEmpty)
    XCTAssertEqual(result.speakerCount, 0)
  }

  func testMapsOnlyValidEmbeddingsForDetectedSpeakers() {
    let result = SpeakerDiarizationResultMapper.map(
      [
        TimedSpeakerSegment(
          speakerId: "S1",
          embedding: [],
          startTimeSeconds: 0,
          endTimeSeconds: 1,
          qualityScore: 1
        ),
      ],
      speakerEmbeddings: [
        "S1": [0.1, 0.2],
        "S2": [0.3, 0.4],
        "invalid": [.nan],
      ]
    )

    XCTAssertEqual(result.speakerEmbeddings, ["S1": [0.1, 0.2]])
  }

  func testNormalizesProgress() {
    XCTAssertEqual(SpeakerDiarizationProgress.fraction(completed: 1, total: 4), 0.25)
    XCTAssertEqual(SpeakerDiarizationProgress.fraction(completed: -1, total: 4), 0)
    XCTAssertEqual(SpeakerDiarizationProgress.fraction(completed: 5, total: 4), 1)
    XCTAssertEqual(SpeakerDiarizationProgress.fraction(completed: 1, total: 0), 0)
  }
}
