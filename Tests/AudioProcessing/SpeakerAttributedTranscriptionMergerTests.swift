@testable import AudioProcessing
import XCTest

final class SpeakerAttributedTranscriptionMergerTests: XCTestCase {
  func testAssignsSpeakersAndPreservesBilingualPunctuation() {
    let segments = SpeakerAttributedTranscriptionMerger.merge(
      transcript: "Hello there. 你好。",
      alignedWords: [
        ForcedAlignmentWord(text: "Hello", startTimeMS: 0, endTimeMS: 400),
        ForcedAlignmentWord(text: "there", startTimeMS: 450, endTimeMS: 900),
        ForcedAlignmentWord(text: "你", startTimeMS: 1100, endTimeMS: 1250),
        ForcedAlignmentWord(text: "好", startTimeMS: 1250, endTimeMS: 1450),
      ],
      speakerSegments: [
        SpeakerDiarizationSegment(speakerID: "S1", startTimeMS: 0, endTimeMS: 1000, qualityScore: 1),
        SpeakerDiarizationSegment(speakerID: "S2", startTimeMS: 1000, endTimeMS: 1500, qualityScore: 1),
      ]
    )

    XCTAssertEqual(segments.count, 2)
    XCTAssertEqual(segments[0].speaker, "S1")
    XCTAssertEqual(segments[0].text, "Hello there.")
    XCTAssertEqual(segments[0].words.map(\.word), ["Hello", "there"])
    XCTAssertEqual(segments[1].speaker, "S2")
    XCTAssertEqual(segments[1].text, "你好。")
    XCTAssertEqual(segments[1].words.map(\.word), ["你", "好"])
  }

  func testUsesMaximumOverlapForWordsCrossingSpeakerBoundaries() {
    let segments = SpeakerAttributedTranscriptionMerger.merge(
      transcript: "crossing",
      alignedWords: [
        ForcedAlignmentWord(text: "crossing", startTimeMS: 800, endTimeMS: 1300),
      ],
      speakerSegments: [
        SpeakerDiarizationSegment(speakerID: "S1", startTimeMS: 0, endTimeMS: 900, qualityScore: 1),
        SpeakerDiarizationSegment(speakerID: "S2", startTimeMS: 900, endTimeMS: 1600, qualityScore: 1),
      ]
    )

    XCTAssertEqual(segments.first?.speaker, "S2")
  }

  func testFillsInteriorDiarizationGapFromNearestIdentifiedSpeaker() {
    let segments = SpeakerAttributedTranscriptionMerger.merge(
      transcript: "first middle last",
      alignedWords: [
        ForcedAlignmentWord(text: "first", startTimeMS: 100, endTimeMS: 300),
        ForcedAlignmentWord(text: "middle", startTimeMS: 2400, endTimeMS: 2600),
        ForcedAlignmentWord(text: "last", startTimeMS: 5000, endTimeMS: 5200),
      ],
      speakerSegments: [
        SpeakerDiarizationSegment(speakerID: "S1", startTimeMS: 0, endTimeMS: 500, qualityScore: 1),
        SpeakerDiarizationSegment(speakerID: "S2", startTimeMS: 4900, endTimeMS: 5400, qualityScore: 1),
      ]
    )

    XCTAssertEqual(segments.count, 2)
    XCTAssertEqual(segments[0].speaker, "S1")
    XCTAssertEqual(segments[0].text, "first middle.")
    XCTAssertEqual(segments[1].speaker, "S2")
    XCTAssertEqual(segments[1].text, "last.")
  }

  func testBackfillsClippedOpeningFromFirstIdentifiedSpeaker() {
    let segments = SpeakerAttributedTranscriptionMerger.merge(
      transcript: "opening words identified later",
      alignedWords: [
        ForcedAlignmentWord(text: "opening", startTimeMS: 1000, endTimeMS: 3000),
        ForcedAlignmentWord(text: "words", startTimeMS: 5000, endTimeMS: 8000),
        ForcedAlignmentWord(text: "identified", startTimeMS: 9000, endTimeMS: 11000),
        ForcedAlignmentWord(text: "later", startTimeMS: 11000, endTimeMS: 13000),
      ],
      speakerSegments: [
        SpeakerDiarizationSegment(speakerID: "S1", startTimeMS: 9000, endTimeMS: 13000, qualityScore: 1),
      ]
    )

    XCTAssertEqual(segments.count, 1)
    XCTAssertEqual(segments[0].speaker, "S1")
    XCTAssertEqual(segments[0].startTimeMS, 1000)
    XCTAssertEqual(segments[0].text, "opening words identified later.")
  }

  func testRestoresPeriodsAtSpeakerChangesAndLongPauses() {
    let segments = SpeakerAttributedTranscriptionMerger.merge(
      transcript: "First thought Second thought 你好",
      alignedWords: [
        ForcedAlignmentWord(text: "First", startTimeMS: 0, endTimeMS: 200),
        ForcedAlignmentWord(text: "thought", startTimeMS: 250, endTimeMS: 500),
        ForcedAlignmentWord(text: "Second", startTimeMS: 2000, endTimeMS: 2200),
        ForcedAlignmentWord(text: "thought", startTimeMS: 2250, endTimeMS: 2500),
        ForcedAlignmentWord(text: "你", startTimeMS: 2700, endTimeMS: 2800),
        ForcedAlignmentWord(text: "好", startTimeMS: 2800, endTimeMS: 2900),
      ],
      speakerSegments: [
        SpeakerDiarizationSegment(speakerID: "S1", startTimeMS: 0, endTimeMS: 2600, qualityScore: 1),
        SpeakerDiarizationSegment(speakerID: "S2", startTimeMS: 2600, endTimeMS: 3000, qualityScore: 1),
      ]
    )

    XCTAssertEqual(segments.count, 2)
    XCTAssertEqual(segments[0].text, "First thought. Second thought.")
    XCTAssertEqual(segments[1].text, "你好。")
    XCTAssertEqual(
      SpeakerAttributedTranscriptionMerger.restoredTranscript(
        from: segments,
        fallback: "fallback"
      ),
      "First thought. Second thought.你好。"
    )
  }

  func testDoesNotGuessOverExistingBoundaryPunctuation() {
    let segments = SpeakerAttributedTranscriptionMerger.merge(
      transcript: "Wait, are you ready? 好的。",
      alignedWords: [
        ForcedAlignmentWord(text: "Wait", startTimeMS: 0, endTimeMS: 200),
        ForcedAlignmentWord(text: "are", startTimeMS: 250, endTimeMS: 350),
        ForcedAlignmentWord(text: "you", startTimeMS: 350, endTimeMS: 450),
        ForcedAlignmentWord(text: "ready", startTimeMS: 450, endTimeMS: 650),
        ForcedAlignmentWord(text: "好", startTimeMS: 900, endTimeMS: 1000),
        ForcedAlignmentWord(text: "的", startTimeMS: 1000, endTimeMS: 1100),
      ],
      speakerSegments: [
        SpeakerDiarizationSegment(speakerID: "S1", startTimeMS: 0, endTimeMS: 700, qualityScore: 1),
        SpeakerDiarizationSegment(speakerID: "S2", startTimeMS: 850, endTimeMS: 1200, qualityScore: 1),
      ]
    )

    XCTAssertEqual(segments.map(\.text), ["Wait, are you ready?", "好的。"])
  }

  func testFallsBackToReadableSpacingWhenTranscriptProjectionFails() {
    let segments = SpeakerAttributedTranscriptionMerger.merge(
      transcript: "different text",
      alignedWords: [
        ForcedAlignmentWord(text: "Hello", startTimeMS: 0, endTimeMS: 100),
        ForcedAlignmentWord(text: "world", startTimeMS: 100, endTimeMS: 200),
        ForcedAlignmentWord(text: "你", startTimeMS: 200, endTimeMS: 300),
        ForcedAlignmentWord(text: "好", startTimeMS: 300, endTimeMS: 400),
      ],
      speakerSegments: []
    )

    XCTAssertNil(segments.first?.speaker)
    XCTAssertEqual(segments.first?.text, "Hello world你好。")
  }

  func testRejectsSparseAlignmentCoverage() {
    XCTAssertFalse(SpeakerAttributionCore.hasSufficientAlignmentCoverage(
      transcript: "one two three four five six seven eight nine ten",
      alignedWordTexts: ["three"]
    ))
    XCTAssertTrue(SpeakerAttributionCore.hasSufficientAlignmentCoverage(
      transcript: "one two three four five",
      alignedWordTexts: ["one", "two", "three", "four", "five"]
    ))
  }

  func testDoesNotAttachUnmatchedTranscriptTailToLastAlignedWord() {
    let segments = SpeakerAttributedTranscriptionMerger.merge(
      transcript: "one two three four five",
      alignedWords: [
        ForcedAlignmentWord(text: "one", startTimeMS: 0, endTimeMS: 100),
        ForcedAlignmentWord(text: "two", startTimeMS: 100, endTimeMS: 200),
      ],
      speakerSegments: []
    )

    XCTAssertEqual(segments.first?.text, "one two.")
  }
}
