import AudioProcessing
import Common
import ComposableArchitecture
@testable import JingoKit
import XCTest

final class SpeakerManagementTests: XCTestCase {
  @MainActor
  func testRenameUpdatesEveryLinkedRecording() async {
    let profileID = UUID()
    let state = SettingsScreen.State()
    state.$speakerProfiles.withLock {
      $0 = [SpeakerProfile(id: profileID, name: "Alice", embedding: [1, 0])]
    }
    state.$recordings.withLock {
      $0 = [linkedRecording(profileID: profileID, name: "Alice")]
    }
    let store = TestStore(initialState: state) {
      SettingsScreen()
    }
    store.exhaustivity = .off

    await store.send(.renameSpeakerSubmitted(profileID, "Jordan"))

    XCTAssertEqual(store.state.speakerProfiles.first?.name, "Jordan")
    XCTAssertEqual(store.state.recordings.first?.speakerNames["speaker-0"], "Jordan")
    XCTAssertEqual(
      store.state.recordings.first?.transcription?.speakerNames["speaker-0"],
      "Jordan"
    )
  }

  @MainActor
  func testForgetRemovesRecognitionLinkButPreservesHistoricalName() async {
    let profileID = UUID()
    let state = SettingsScreen.State()
    state.$speakerProfiles.withLock {
      $0 = [SpeakerProfile(id: profileID, name: "Alice", embedding: [1, 0])]
    }
    state.$recordings.withLock {
      $0 = [linkedRecording(profileID: profileID, name: "Alice")]
    }
    let store = TestStore(initialState: state) {
      SettingsScreen()
    }
    store.exhaustivity = .off

    await store.send(.forgetSpeakerTapped(profileID))

    XCTAssertTrue(store.state.speakerProfiles.isEmpty)
    XCTAssertTrue(store.state.recordings.first?.transcription?.speakerProfileIDs.isEmpty == true)
    XCTAssertEqual(store.state.recordings.first?.speakerNames["speaker-0"], "Alice")
    XCTAssertEqual(
      store.state.recordings.first?.transcription?.speakerNames["speaker-0"],
      "Alice"
    )
  }

  @MainActor
  func testBulkRemoveClearsEverySelectedRecognitionLink() async {
    let aliceID = UUID()
    let bobID = UUID()
    let state = SettingsScreen.State()
    state.$speakerProfiles.withLock {
      $0 = [
        SpeakerProfile(id: aliceID, name: "Alice", embedding: [1, 0]),
        SpeakerProfile(id: bobID, name: "Bob", embedding: [0, 1]),
      ]
    }
    state.$recordings.withLock {
      $0 = [linkedRecording(profileIDs: ["speaker-0": aliceID, "speaker-1": bobID])]
    }
    let store = TestStore(initialState: state) {
      SettingsScreen()
    }
    store.exhaustivity = .off

    await store.send(.forgetSpeakersTapped([aliceID, bobID]))

    XCTAssertTrue(store.state.speakerProfiles.isEmpty)
    XCTAssertTrue(store.state.recordings.first?.transcription?.speakerProfileIDs.isEmpty == true)
    XCTAssertEqual(store.state.recordings.first?.speakerNames["speaker-0"], "Alice")
    XCTAssertEqual(store.state.recordings.first?.speakerNames["speaker-1"], "Bob")
  }

  @MainActor
  func testMergeCombinesSamplesAndRelinksRecordings() async {
    let aliceID = UUID()
    let duplicateID = UUID()
    let state = SettingsScreen.State()
    state.$speakerProfiles.withLock {
      $0 = [
        SpeakerProfile(id: aliceID, name: "Alice", embedding: [1, 0], sampleCount: 2),
        SpeakerProfile(id: duplicateID, name: "A. Smith", embedding: [0.9, 0.1], sampleCount: 3),
      ]
    }
    state.$recordings.withLock {
      $0 = [linkedRecording(profileIDs: ["speaker-0": duplicateID])]
    }
    let store = TestStore(initialState: state) {
      SettingsScreen()
    }
    store.exhaustivity = .off

    await store.send(
      .mergeSpeakerProfilesSubmitted([aliceID, duplicateID], into: aliceID, name: "Alice Smith")
    )

    XCTAssertEqual(store.state.speakerProfiles.count, 1)
    XCTAssertEqual(store.state.speakerProfiles.first?.id, aliceID)
    XCTAssertEqual(store.state.speakerProfiles.first?.name, "Alice Smith")
    XCTAssertEqual(store.state.speakerProfiles.first?.voiceSamples.count, 2)
    XCTAssertEqual(store.state.speakerProfiles.first?.sampleCount, 5)
    XCTAssertEqual(
      store.state.recordings.first?.transcription?.speakerProfileIDs["speaker-0"],
      aliceID
    )
    XCTAssertEqual(store.state.recordings.first?.speakerNames["speaker-0"], "Alice Smith")
    XCTAssertEqual(
      store.state.recordings.first?.transcription?.speakerNames["speaker-0"],
      "Alice Smith"
    )
  }

  private func linkedRecording(profileID: UUID, name: String) -> RecordingInfo {
    RecordingInfo(
      fileName: "linked.wav",
      date: Date(timeIntervalSince1970: 0),
      transcription: Transcription(
        fileName: "linked.wav",
        parameters: TranscriptionParameters(),
        model: "test",
        speakerProfileIDs: ["speaker-0": profileID],
        speakerNames: ["speaker-0": name]
      ),
      speakerNames: ["speaker-0": name]
    )
  }

  private func linkedRecording(profileIDs: [String: UUID]) -> RecordingInfo {
    let names = ["speaker-0": "Alice", "speaker-1": "Bob"]
    return RecordingInfo(
      fileName: "linked.wav",
      date: Date(timeIntervalSince1970: 0),
      transcription: Transcription(
        fileName: "linked.wav",
        parameters: TranscriptionParameters(),
        model: "test",
        speakerProfileIDs: profileIDs,
        speakerNames: names
      ),
      speakerNames: names
    )
  }
}
