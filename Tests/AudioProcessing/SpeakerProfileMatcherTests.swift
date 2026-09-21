@testable import AudioProcessing
import XCTest

final class SpeakerProfileMatcherTests: XCTestCase {
  func testMatchesStrongestUnambiguousProfile() throws {
    let alice = SpeakerProfile(name: "Alice", embedding: [1, 0])
    let bob = SpeakerProfile(name: "Bob", embedding: [0, 1])

    let matches = SpeakerProfileMatcher.matches(
      speakerEmbeddings: ["speaker-0": [0.99, 0.05]],
      profiles: [alice, bob]
    )

    let match = try XCTUnwrap(matches["speaker-0"])
    XCTAssertEqual(match.profileID, alice.id)
    XCTAssertEqual(match.name, "Alice")
  }

  func testRejectsWeakAndAmbiguousMatches() {
    let first = SpeakerProfile(name: "First", embedding: [1, 0])
    let second = SpeakerProfile(name: "Second", embedding: [0.99, 0.01])

    XCTAssertTrue(SpeakerProfileMatcher.matches(
      speakerEmbeddings: ["speaker-0": [0, 1]],
      profiles: [first]
    ).isEmpty)
    XCTAssertTrue(SpeakerProfileMatcher.matches(
      speakerEmbeddings: ["speaker-0": [1, 0]],
      profiles: [first, second]
    ).isEmpty)
  }

  func testDoesNotAssignOneProfileToTwoSpeakers() {
    let profile = SpeakerProfile(name: "Alice", embedding: [1, 0])
    let matches = SpeakerProfileMatcher.matches(
      speakerEmbeddings: [
        "speaker-0": [1, 0],
        "speaker-1": [0.99, 0.01],
      ],
      profiles: [profile]
    )

    XCTAssertEqual(matches.count, 1)
    XCTAssertEqual(matches["speaker-0"]?.profileID, profile.id)
  }

  func testMatchesAStrongShortChunkWhenTheAggregateIsWeak() throws {
    let alice = SpeakerProfile(name: "Alice", embedding: [1, 0])
    let matches = SpeakerProfileMatcher.matches(
      speakerEmbeddingCandidates: [
        "speaker-0": [
          [0.7, 0.7],
          [0.99, 0.05],
        ],
      ],
      profiles: [alice]
    )

    let match = try XCTUnwrap(matches["speaker-0"])
    XCTAssertTrue(match.profileID == alice.id)
  }

  func testShortChunkMatchingStillRejectsAmbiguousProfiles() {
    let first = SpeakerProfile(name: "First", embedding: [1, 0])
    let second = SpeakerProfile(name: "Second", embedding: [0.99, 0.01])

    XCTAssertTrue(SpeakerProfileMatcher.matches(
      speakerEmbeddingCandidates: ["speaker-0": [[1, 0]]],
      profiles: [first, second]
    ).isEmpty)
  }

  func testAcceptsClearFallbackMatch() throws {
    let alice = SpeakerProfile(name: "Alice", embedding: [1, 0, 0])
    let bob = SpeakerProfile(name: "Bob", embedding: [0, 1, 0])
    let matches = SpeakerProfileMatcher.matches(
      speakerEmbeddings: ["speaker-0": [0.63, 0.20, 0.75]],
      profiles: [alice, bob],
      fallbackSimilarity: SpeakerProfileMatcher.fallbackMinimumSimilarity,
      fallbackMargin: SpeakerProfileMatcher.fallbackMinimumMargin
    )

    let match = try XCTUnwrap(matches["speaker-0"])
    XCTAssertEqual(match.profileID, alice.id)
    XCTAssertEqual(match.name, "Alice")
  }

  func testRejectsWeakFallbackMatch() {
    let alice = SpeakerProfile(name: "Alice", embedding: [1, 0, 0])
    let bob = SpeakerProfile(name: "Bob", embedding: [0, 1, 0])

    XCTAssertTrue(SpeakerProfileMatcher.matches(
      speakerEmbeddings: ["speaker-0": [0.55, 0.10, 0.83]],
      profiles: [alice, bob],
      fallbackSimilarity: SpeakerProfileMatcher.fallbackMinimumSimilarity,
      fallbackMargin: SpeakerProfileMatcher.fallbackMinimumMargin
    ).isEmpty)
  }

  func testRejectsAmbiguousFallbackMatch() {
    let alice = SpeakerProfile(name: "Alice", embedding: [1, 0, 0])
    let bob = SpeakerProfile(name: "Bob", embedding: [0, 1, 0])

    XCTAssertTrue(SpeakerProfileMatcher.matches(
      speakerEmbeddings: ["speaker-0": [0.65, 0.55, 0.52]],
      profiles: [alice, bob],
      fallbackSimilarity: SpeakerProfileMatcher.fallbackMinimumSimilarity,
      fallbackMargin: SpeakerProfileMatcher.fallbackMinimumMargin
    ).isEmpty)
  }

  func testEnrollCreatesThenUpdatesNamedProfile() throws {
    var profiles: [SpeakerProfile] = []
    let profileID = try XCTUnwrap(SpeakerProfileMatcher.enroll(
      name: " Alice ",
      embedding: [2, 0],
      linkedProfileID: nil,
      profiles: &profiles,
      now: Date(timeIntervalSince1970: 1)
    ))
    let updatedID = SpeakerProfileMatcher.enroll(
      name: "alice",
      embedding: [1, 0.1],
      linkedProfileID: nil,
      profiles: &profiles,
      now: Date(timeIntervalSince1970: 2)
    )

    XCTAssertEqual(updatedID, profileID)
    XCTAssertEqual(profiles.count, 1)
    XCTAssertEqual(profiles[0].sampleCount, 2)
    XCTAssertEqual(profiles[0].updatedAt, Date(timeIntervalSince1970: 2))
    let similarity = try XCTUnwrap(SpeakerProfileMatcher.cosineSimilarity(
      profiles[0].embedding,
      profiles[0].embedding
    ))
    XCTAssertEqual(
      similarity,
      1,
      accuracy: 0.0001
    )
  }

  func testRejectsInvalidEmbeddings() {
    XCTAssertNil(SpeakerProfileMatcher.cosineSimilarity([], []))
    XCTAssertNil(SpeakerProfileMatcher.cosineSimilarity([1], [1, 0]))
    XCTAssertNil(SpeakerProfileMatcher.cosineSimilarity([.nan], [1]))
  }

  func testAddingSampleToLinkedProfileUpdatesEmbeddingAndCount() {
    let profileID = UUID()
    var profiles = [
      SpeakerProfile(id: profileID, name: "Alice", embedding: [1, 0], sampleCount: 2),
    ]

    let updatedID = SpeakerProfileMatcher.enroll(
      name: "Alice",
      embedding: [0.9, 0.1],
      linkedProfileID: profileID,
      profiles: &profiles
    )

    XCTAssertEqual(updatedID, profileID)
    XCTAssertEqual(profiles[0].sampleCount, 3)
    XCTAssertGreaterThan(profiles[0].embedding[1], 0)
  }

  func testEnrollmentUsesSingleDominantSpeaker() throws {
    let embedding = try SpeakerProfileMatcher.enrollmentEmbedding(
      speechDurationMSBySpeaker: ["speaker-0": 9000, "speaker-1": 1000],
      speakerEmbeddings: [
        "speaker-0": [2, 0],
        "speaker-1": [0, 1],
      ]
    )

    XCTAssertEqual(embedding, [1, 0])
  }

  func testEnrollmentRejectsShortAndMultiSpeakerSamples() {
    XCTAssertThrowsError(try SpeakerProfileMatcher.enrollmentEmbedding(
      speechDurationMSBySpeaker: ["speaker-0": 5500],
      speakerEmbeddings: ["speaker-0": [1, 0]]
    )) { error in
      XCTAssertEqual(error as? SpeakerProfileEnrollmentError, .insufficientSpeech)
    }

    XCTAssertThrowsError(try SpeakerProfileMatcher.enrollmentEmbedding(
      speechDurationMSBySpeaker: ["speaker-0": 6000, "speaker-1": 2000],
      speakerEmbeddings: [
        "speaker-0": [1, 0],
        "speaker-1": [0, 1],
      ]
    )) { error in
      XCTAssertEqual(error as? SpeakerProfileEnrollmentError, .multipleSpeakers)
    }
  }

  func testEnrollmentAcceptsSixSecondsOfSpeech() throws {
    let embedding = try SpeakerProfileMatcher.enrollmentEmbedding(
      speechDurationMSBySpeaker: ["speaker-0": 6000],
      speakerEmbeddings: ["speaker-0": [1, 0]]
    )

    XCTAssertEqual(embedding, [1, 0])
  }

  func testRenameRejectsDuplicateName() throws {
    let aliceID = UUID()
    var profiles = [
      SpeakerProfile(id: aliceID, name: "Alice", embedding: [1, 0]),
      SpeakerProfile(name: "Bob", embedding: [0, 1]),
    ]

    XCTAssertThrowsError(try SpeakerProfileMatcher.rename(
      profileID: aliceID,
      to: " bob ",
      profiles: &profiles
    )) { error in
      XCTAssertEqual(error as? SpeakerProfileEnrollmentError, .duplicateName)
    }
    XCTAssertEqual(profiles[0].name, "Alice")
  }
}
