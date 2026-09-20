import Common
import Foundation

// MARK: - SpeakerAttributedTranscriptionMerger

enum SpeakerAttributedTranscriptionMerger {
  static func merge(
    transcript: String,
    alignedWords: [ForcedAlignmentWord],
    speakerSegments: [SpeakerDiarizationSegment]
  ) -> [Segment] {
    SpeakerAttributionCore.merge(
      transcript: transcript,
      words: alignedWords.map {
        SpeakerAttributionWord(
          text: $0.text,
          startTimeMS: $0.startTimeMS,
          endTimeMS: $0.endTimeMS
        )
      },
      speakerIntervals: speakerSegments.map {
        SpeakerAttributionInterval(
          speakerID: $0.speakerID,
          startTimeMS: $0.startTimeMS,
          endTimeMS: $0.endTimeMS
        )
      }
    )
    .map { turn in
      Segment(
        startTimeMS: turn.startTimeMS,
        endTimeMS: turn.endTimeMS,
        text: turn.text,
        tokens: [],
        speaker: turn.speakerID,
        words: turn.words.map { word in
          WordData(
            word: word.text,
            startTimeMS: word.startTimeMS,
            endTimeMS: word.endTimeMS,
            probability: 1
          )
        }
      )
    }
  }

  static func restoredTranscript(
    from segments: [Segment],
    fallback: String
  ) -> String {
    let restoredText = SpeakerAttributionCore.joinTranscript(segments.map(\.text))
    return restoredText.isEmpty ? fallback : restoredText
  }
}
