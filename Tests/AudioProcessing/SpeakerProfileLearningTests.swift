@testable import AudioProcessing
import XCTest

// AudioProcessingTests does not link CustomDump.
// swiftlint:disable xctassertnodifference_preferred
final class SpeakerProfileLearningTests: XCTestCase {
  func testConfirmedOutlierWaitsForCorroboration() throws {
    let profileID = UUID()
    var profiles = [SpeakerProfile(id: profileID, name: "Alice", embedding: [1, 0])]
    let firstRecordingID = UUID()

    let firstResult = try XCTUnwrap(SpeakerProfileMatcher.learn(
      name: "Alice",
      embedding: [0, 1],
      linkedProfileID: profileID,
      profiles: &profiles,
      source: .confirmedRecording,
      sourceRecordingID: firstRecordingID.uuidString,
      sourceSpeakerID: "speaker-0"
    ))

    XCTAssertEqual(firstResult.outcome, .pending)
    XCTAssertEqual(profiles[0].voiceSamples.count, 1)
    XCTAssertEqual(profiles[0].pendingVoiceSamples.count, 1)

    let secondResult = try XCTUnwrap(SpeakerProfileMatcher.learn(
      name: "Alice",
      embedding: [0.02, 0.999],
      linkedProfileID: profileID,
      profiles: &profiles,
      source: .confirmedRecording,
      sourceRecordingID: UUID().uuidString,
      sourceSpeakerID: "speaker-1"
    ))

    XCTAssertEqual(secondResult.outcome, .addedCoverage)
    XCTAssertEqual(profiles[0].voiceSamples.count, 2)
    XCTAssertTrue(profiles[0].pendingVoiceSamples.isEmpty)
  }

  func testSameRecordingSpeakerCannotBeLearnedTwice() throws {
    let profileID = UUID()
    let recordingID = UUID()
    var profiles = [SpeakerProfile(id: profileID, name: "Alice", embedding: [1, 0])]

    _ = SpeakerProfileMatcher.learn(
      name: "Alice",
      embedding: [0.8, 0.6],
      linkedProfileID: profileID,
      profiles: &profiles,
      source: .confirmedRecording,
      sourceRecordingID: recordingID.uuidString,
      sourceSpeakerID: "speaker-0"
    )
    let repeatedResult = try XCTUnwrap(SpeakerProfileMatcher.learn(
      name: "Alice",
      embedding: [0.7, 0.7],
      linkedProfileID: profileID,
      profiles: &profiles,
      source: .confirmedRecording,
      sourceRecordingID: recordingID.uuidString,
      sourceSpeakerID: "speaker-0"
    ))

    XCTAssertEqual(repeatedResult.outcome, .duplicate)
    XCTAssertEqual(profiles[0].voiceSamples.count, 2)
  }

  func testReassignmentRemovesObservationFromPreviousProfile() {
    let recordingID = UUID()
    let aliceSample = SpeakerVoiceSample(
      embedding: [0.8, 0.6],
      source: .confirmedRecording,
      sourceRecordingID: recordingID.uuidString,
      sourceSpeakerID: "speaker-0"
    )
    var profiles = [
      SpeakerProfile(
        name: "Alice",
        voiceSamples: [
          SpeakerVoiceSample(embedding: [1, 0], source: .legacy),
          aliceSample,
        ]
      ),
      SpeakerProfile(name: "Bob", embedding: [0.2, 0.98]),
    ]

    _ = SpeakerProfileMatcher.learn(
      name: "Bob",
      embedding: [0.8, 0.6],
      linkedProfileID: profiles[0].id,
      profiles: &profiles,
      source: .confirmedRecording,
      sourceRecordingID: recordingID.uuidString,
      sourceSpeakerID: "speaker-0"
    )

    XCTAssertEqual(profiles[0].voiceSamples.count, 1)
    XCTAssertEqual(profiles[1].voiceSamples.count, 2)
  }

  func testReassignmentToNewProfileRemovesObservationFromPreviousProfile() {
    let recordingID = UUID().uuidString
    var profiles = [
      SpeakerProfile(
        name: "Alice",
        voiceSamples: [
          SpeakerVoiceSample(embedding: [1, 0], source: .legacy),
          SpeakerVoiceSample(
            embedding: [0.8, 0.6],
            source: .confirmedRecording,
            sourceRecordingID: recordingID,
            sourceSpeakerID: "speaker-0"
          ),
        ]
      ),
    ]

    _ = SpeakerProfileMatcher.learn(
      name: "Bob",
      embedding: [0.8, 0.6],
      linkedProfileID: profiles[0].id,
      profiles: &profiles,
      source: .confirmedRecording,
      sourceRecordingID: recordingID,
      sourceSpeakerID: "speaker-0"
    )

    XCTAssertEqual(profiles.count, 2)
    XCTAssertEqual(profiles[0].voiceSamples.count, 1)
    XCTAssertEqual(profiles[1].name, "Bob")
    XCTAssertEqual(profiles[1].voiceSamples.count, 1)
  }

  func testMatchesAnyActiveRepresentative() throws {
    let profile = SpeakerProfile(
      name: "Alice",
      voiceSamples: [
        SpeakerVoiceSample(embedding: [1, 0], source: .legacy),
        SpeakerVoiceSample(embedding: [0, 1], source: .confirmedRecording),
      ]
    )

    let matches = SpeakerProfileMatcher.matches(
      speakerEmbeddings: ["speaker-0": [0.05, 0.99]],
      profiles: [profile]
    )

    XCTAssertEqual(try XCTUnwrap(matches["speaker-0"]).profileID, profile.id)
  }

  func testDecodesLegacyProfileAsSingleRepresentative() throws {
    struct LegacyProfile: Codable {
      let id: UUID
      let name: String
      let embedding: [Float]
      let sampleCount: Int
      let updatedAt: Date
    }

    let legacy = LegacyProfile(
      id: UUID(),
      name: "Alice",
      embedding: [2, 0],
      sampleCount: 4,
      updatedAt: Date(timeIntervalSince1970: 10)
    )
    let profile = try JSONDecoder().decode(
      SpeakerProfile.self,
      from: JSONEncoder().encode(legacy)
    )

    XCTAssertEqual(profile.id, legacy.id)
    XCTAssertEqual(profile.sampleCount, 4)
    XCTAssertEqual(profile.voiceSamples.count, 1)
    XCTAssertEqual(profile.voiceSamples[0].source, .legacy)
    XCTAssertEqual(profile.voiceSamples[0].embedding, [2, 0])
  }
}
// swiftlint:enable xctassertnodifference_preferred
