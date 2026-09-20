import AudioProcessing
import BackgroundTasks
import Combine
import Common
import ComposableArchitecture
import Dependencies
import IdentifiedCollections
import UIKit

// MARK: - TranscriptionWorkerClient

@Reducer
struct TranscriptionWorker: Reducer {
  @ObservableState
  struct State: Equatable {
    @Shared(.transcriptionTasks) var taskQueue: IdentifiedArrayOf<TranscriptionTask>
    @Shared(.recordings) var recordings: IdentifiedArrayOf<RecordingInfo>
    @Shared(.speakerProfiles) var speakerProfiles: [SpeakerProfile]
    var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var isProcessing: Bool {
      currentTask != nil
    }

    var currentTask: TranscriptionTask?
  }

  enum Action {
    case processTasks
    case handleBGProcessingTask(BGProcessingTask)
    case beginBackgroundTask
    case endBackgroundTask
    case scheduleBackgroundProcessingTask
    case cancelScheduledBackgroundProcessingTask
    case enqueueTaskForRecordingID(RecordingInfo.ID, Settings)
    case cancelTaskForRecordingID(RecordingInfo.ID)
    case cancelAllTasks
    case resumeTask(TranscriptionTask)
    case setCurrentTask(TranscriptionTask)
    case currentTaskFinishProcessing
    case setBackgroundTask(UIBackgroundTaskIdentifier)
    case transcriptionDidUpdate(Transcription, task: TranscriptionTask)
  }

  static let backgroundTaskIdentifier = "com.feiyiwang.Jingo"

  enum CancelID: Hashable { case processing }

  @Dependency(RecordingTranscriptionStream.self) var transcriptionStream: RecordingTranscriptionStream

  var body: some Reducer<State, Action> {
    Reduce<State, Action> { state, action in
      switch action {
      case .processTasks:
        guard !state.isProcessing else {
          return .none
        }

        if let (task, recording) = getNextTask(state: state) {
          let speakerProfiles = state.speakerProfiles
          return .run { send in
            await send(.setCurrentTask(task))
            await send(.beginBackgroundTask)
            await send(.scheduleBackgroundProcessingTask)
            await process(
              task: task,
              recording: recording,
              speakerProfiles: speakerProfiles
            ) { transcription in
              await send(.transcriptionDidUpdate(transcription, task: task))
            }
            await send(.endBackgroundTask)
            await send(.cancelScheduledBackgroundProcessingTask)
            await send(.currentTaskFinishProcessing)
          }
          .cancellable(id: CancelID.processing, cancelInFlight: true)
        } else {
          return .none
        }

      case let .handleBGProcessingTask(bgTask):
        return .run { send in
          bgTask.expirationHandler = {}
          await send(.processTasks)
        }

      case .beginBackgroundTask:
        guard state.isProcessing else {
          return .none
        }
        return .run { send in
          let taskIdentifier = await MainActor.run {
            UIApplication.shared.beginBackgroundTask {
              send(.endBackgroundTask)
            }
          }
          await send(.setBackgroundTask(taskIdentifier))
        }

      case .endBackgroundTask:
        return .send(.setBackgroundTask(.invalid))

      case let .setBackgroundTask(taskIdentifier):
        if state.backgroundTask != .invalid {
          UIApplication.shared.endBackgroundTask(state.backgroundTask)
        }
        state.backgroundTask = taskIdentifier
        return .none

      case .scheduleBackgroundProcessingTask:
        guard state.isProcessing else {
          return .none
        }
        let request = BGProcessingTaskRequest(identifier: TranscriptionWorker.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 1)

        do {
          try BGTaskScheduler.shared.submit(request)
        } catch {
          logs.error("Could not schedule background task: \(error)")
        }
        return .none

      case .cancelScheduledBackgroundProcessingTask:
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: TranscriptionWorker.backgroundTaskIdentifier)
        return .none

      case let .enqueueTaskForRecordingID(id, settings):
        let task = TranscriptionTask(recordingInfoID: id, settings: settings)
        state.$taskQueue.withLock {
          $0.removeAll(where: { $0.recordingInfoID == id })
          $0.append(task)
        }
        return .send(.processTasks)

      case let .cancelTaskForRecordingID(id):
        let task = state.taskQueue.first { task in
          task.recordingInfoID == id
        }

        let isCurrent = state.currentTask?.id == task?.id && task != nil
        state.$taskQueue.withLock { $0.removeAll { $0.recordingInfoID == id } }

        guard isCurrent else {
          return .none
        }
        state.currentTask = nil
        let processNextTask: Effect<Action> = state.taskQueue.isEmpty ? .none : .send(.processTasks)
        return .merge(
          .cancel(id: CancelID.processing),
          .send(.endBackgroundTask),
          .send(.cancelScheduledBackgroundProcessingTask),
          processNextTask
        )

      case .cancelAllTasks:
        state.$taskQueue.withLock { $0.removeAll() }
        state.currentTask = nil
        return .merge(
          .cancel(id: CancelID.processing),
          .send(.endBackgroundTask),
          .send(.cancelScheduledBackgroundProcessingTask)
        )

      case let .resumeTask(task):
        _ = state.$taskQueue.withLock { $0.insert(task, at: 0) }
        return .send(.processTasks)

      case let .setCurrentTask(task):
        state.currentTask = task
        return .none

      case .currentTaskFinishProcessing:
        if let currentTask = state.currentTask {
          state.$taskQueue.withLock { $0.removeAll { $0.id == currentTask.id } }
        }
        state.currentTask = nil
        return .run { send in
          await send(.processTasks) // Send processTasks action again after finishing the current task
        }

      case let .transcriptionDidUpdate(transcription, task: task):
        guard state.taskQueue[id: task.id] != nil else {
          return .none
        }
        state.$recordings.withLock { recordings in
          if let recordingIndex = recordings.firstIndex(where: { $0.id == task.recordingInfoID }) {
            recordings[recordingIndex].transcription = transcription
            for (speakerID, name) in transcription.speakerNames
              where recordings[recordingIndex].speakerNames[speakerID] == nil {
              recordings[recordingIndex].speakerNames[speakerID] = name
            }
          }
        }
        return .none
      }
    }
  }

  private func getNextTask(state: State) -> (task: TranscriptionTask, recording: RecordingInfo)? {
    state.$taskQueue.withLock { taskQueue in
      while let task = taskQueue.first {
        if let recording = state.recordings.first(where: { $0.id == task.recordingInfoID }) {
          return (task: task, recording: recording)
        }
        taskQueue.removeFirst()
      }
      return nil
    }
  }

  func process(
    task: TranscriptionTask,
    recording: RecordingInfo,
    speakerProfiles: [SpeakerProfile],
    callback: @escaping (Transcription) async -> Void
  ) async {
    logs.debug("Starting transcription process for task ID: \(task.id)")
    defer {
      logs.debug("Ending transcription process for task ID: \(task.id)")
    }

    let model = task.settings.selectedModelName

    let transcription = LockIsolated(Transcription(
      id: task.id,
      fileName: recording.fileName,
      parameters: task.settings.parameters,
      model: model
    ))

    let updateClosure: ((inout Transcription) -> Void) -> Void = { update in
      transcription.withValue { transcription in
        update(&transcription)
      }
      Task { @MainActor in
        await callback(transcription.value)
      }
    }

    let fileURL = recording.fileURL
    logs.debug("File URL for task ID \(task.id): \(fileURL)")

    do {
      guard FileManager.default.fileExists(atPath: fileURL.path) else {
        throw NSError(
          domain: "TranscriptionWorker",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "The recording audio is missing. Please make a new recording."]
        )
      }
      let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
      guard values.fileSize.map({ $0 > 0 }) == true else {
        throw NSError(
          domain: "TranscriptionWorker",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "The recording audio is missing. Please make a new recording."]
        )
      }

      logs.debug("Setting transcription status to loading for task ID: \(task.id)")
      updateClosure { $0.status = .loading }

      // MARK: Load model

      try await transcriptionStream.loadModel(model) { _ in }

      logs.debug("Model (\(model)) loaded for task ID \(task.id)")

      // MARK: Transcription

      updateClosure { $0.status = .progress(0, text: "") }

      let result = try await transcriptionStream.transcribeAudioFile(fileURL) { progress, fraction in
        updateClosure { transcription in
          transcription.status = .progress(fraction, text: progress.text)
        }
        return true
      }

      logs.debug("Setting transcription status to done for task ID: \(task.id)")

      updateClosure { transcription in
        let speakerMatches = SpeakerProfileMatcher.matches(
          speakerEmbeddings: result.speakerEmbeddings,
          profiles: speakerProfiles
        )
        transcription.segments = result.segments
        transcription.text = result.text
        transcription.status = .done(Date())
        transcription.timings = Transcription.Timings(tokensPerSecond: result.timings.tokensPerSecond, fullPipeline: result.timings.fullPipeline)
        transcription.speakerEmbeddings = result.speakerEmbeddings
        transcription.speakerProfileIDs = speakerMatches.mapValues(\.profileID)
        transcription.speakerNames = speakerMatches.mapValues(\.name)
      }
    } catch is CancellationError {
      logs.debug("Cancelled transcription for task ID \(task.id)")
    } catch {
      logs.error("Error during transcription for task ID \(task.id): \(error.localizedDescription)")
      updateClosure { transcription in
        transcription.status = .error(message: error.localizedDescription)
      }
    }
  }
}
