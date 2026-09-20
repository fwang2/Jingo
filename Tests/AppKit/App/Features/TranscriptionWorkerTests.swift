import Common
import ComposableArchitecture
@testable import JingoKit
import XCTest

final class TranscriptionWorkerTests: XCTestCase {
  @MainActor
  func testCancellingCurrentTaskClearsProcessingState() async {
    let task = TranscriptionTask(recordingInfoID: "recording-id", settings: Settings())
    var state = TranscriptionWorker.State()
    state.$taskQueue.withLock { $0 = [task] }
    state.currentTask = task
    let store = TestStore(initialState: state) {
      TranscriptionWorker()
    }
    store.exhaustivity = .off

    await store.send(.cancelTaskForRecordingID(task.recordingInfoID)) {
      $0.$taskQueue.withLock { $0 = [] }
      $0.currentTask = nil
    }
    await store.skipReceivedActions(strict: false)

    XCTAssertNil(store.state.currentTask)
    XCTAssertTrue(store.state.taskQueue.isEmpty)
    XCTAssertFalse(store.state.isProcessing)
  }

  @MainActor
  func testLateUpdateFromCancelledTaskIsIgnored() async {
    let task = TranscriptionTask(recordingInfoID: "recording-id", settings: Settings())
    let recording = RecordingInfo(fileName: "recording.wav", date: Date(timeIntervalSince1970: 0))
    let state = TranscriptionWorker.State()
    state.$taskQueue.withLock { $0 = [] }
    state.$recordings.withLock { $0 = [recording] }
    let store = TestStore(initialState: state) {
      TranscriptionWorker()
    }

    let transcription = Transcription(
      id: task.id,
      fileName: recording.fileName,
      parameters: task.settings.parameters,
      model: task.settings.selectedModelName,
      status: .done(Date(timeIntervalSince1970: 1)),
      text: "Late update"
    )
    await store.send(.transcriptionDidUpdate(transcription, task: task))

    XCTAssertNil(store.state.recordings[id: recording.id]?.transcription)
  }
}
