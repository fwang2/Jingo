import Common
import ComposableArchitecture
@testable import JingoKit
import XCTest

final class RecordingTests: XCTestCase {
  @MainActor
  func testRecordingRegistersActiveFileForItsLifetime() async {
    let recording = RecordingInfo(fileName: "active-recording.wav", date: Date(timeIntervalSince1970: 0))
    let activeURLs = LockIsolated<[URL?]>([])
    let store = TestStore(
      initialState: Recording.State(recordingInfo: recording, isLiveTranscriptionEnabled: false)
    ) {
      Recording()
    } withDependencies: {
      $0[StorageClient.self].setCurrentRecordingURL = { url in
        activeURLs.withValue { $0.append(url) }
      }
    }
    store.exhaustivity = .off

    await store.send(.onTask).finish()

    XCTAssertEqual(activeURLs.value, [recording.fileURL, nil])
  }
}
