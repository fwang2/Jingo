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
}
