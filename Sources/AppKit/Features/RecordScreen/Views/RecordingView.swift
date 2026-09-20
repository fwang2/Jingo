@preconcurrency import AudioProcessing
import Common
import ComposableArchitecture
import Dependencies
import DSWaveformImage
import DSWaveformImageViews
import Foundation
import Inject
import Popovers
import SwiftUI

// MARK: - Recording

@Reducer
struct Recording {
  @ObservableState
  struct State: Equatable {
    enum Mode: Equatable {
      case recording, saving, paused, removing
    }

    enum LiveTranscriptionState: Equatable {
      case modelLoading(Double), transcribing

      var modelProgress: Double? {
        if case let .modelLoading(progress) = self {
          return progress
        }
        return nil
      }
    }

    var mode: Mode = .recording
    var isModelLoadingInfoPresented = false

    @Shared var recordingInfo: RecordingInfo
    @Shared var samples: [Float]
    @Shared var liveTranscriptionState: LiveTranscriptionState?
    var isLiveTranscriptionEnabled: Bool

    init(recordingInfo: RecordingInfo, isLiveTranscriptionEnabled: Bool) {
      _recordingInfo = Shared(value: recordingInfo)
      _samples = Shared(value: [])
      _liveTranscriptionState = Shared(value: nil)
      self.isLiveTranscriptionEnabled = isLiveTranscriptionEnabled
    }
  }

  enum Action: Equatable, BindableAction {
    case binding(BindingAction<State>)
    case delegate(Delegate)
    case onTask
    case saveButtonTapped
    case pauseButtonTapped
    case continueButtonTapped
    case deleteButtonTapped
    case toggleModelLoadingInfo

    enum Delegate: Equatable {
      case didFinish(TaskResult<State>)
      case didCancel
    }
  }

  @Dependency(RecordingTranscriptionStream.self) var transcriptionStream: RecordingTranscriptionStream
  @Dependency(StorageClient.self) var storage: StorageClient

  var body: some ReducerOf<Self> {
    BindingReducer()

    Reduce { state, action in
      switch action {
      case .binding:
        return .none

      case .delegate:
        return .none

      case .onTask:
        state.mode = .recording

        return .run { [
          liveTranscriptionState = state.$liveTranscriptionState,
          recordingInfo = state.$recordingInfo,
          isLiveTranscriptionEnabled = state.isLiveTranscriptionEnabled
        ] _ in
          storage.setCurrentRecordingURL(url: recordingInfo.wrappedValue.fileURL)
          defer { storage.setCurrentRecordingURL(url: nil) }

          generateImpact()

          @Shared(.settings) var settings: Settings

          let transcription = Transcription(
            fileName: recordingInfo.wrappedValue.fileName,
            parameters: settings.parameters,
            model: settings.selectedModelName
          )

          recordingInfo.withLock { recordingInfo in
            recordingInfo.transcription = transcription
          }

          try await withThrowingTaskGroup(of: Void.self) { [selectedModelName = settings.selectedModelName] group in
            if isLiveTranscriptionEnabled {
              group.addTask {
                do {
                  liveTranscriptionState.withLock { liveTranscriptionState in
                    liveTranscriptionState = .modelLoading(0)
                  }
                  try await transcriptionStream.loadModel(selectedModelName) { progress in
                    liveTranscriptionState.withLock { liveTranscriptionState in
                      liveTranscriptionState = .modelLoading(progress)
                    }
                  }

                  for try await transcriptionState in await transcriptionStream.startLiveTranscription() {
                    liveTranscriptionState.withLock { liveTranscriptionState in
                      liveTranscriptionState = .transcribing
                    }

                    let transcriptionSegments = transcriptionState.segments
                    recordingInfo.withLock { recordingInfo in
                      recordingInfo.transcription?.segments = transcriptionSegments
                      recordingInfo.transcription?.text = transcriptionSegments.map(\.text).joined(separator: " ")
                      recordingInfo.transcription?.timings = .init(tokensPerSecond: transcriptionState.tokensPerSecond)
                    }
                  }
                } catch {
                  await transcriptionStream.stopRecording()
                  throw error
                }
              }
            }

            group.addTask {
              for try await recordingState in await transcriptionStream.startRecording(recordingInfo.wrappedValue.fileURL) {
                // samples.withLock { samples in
                //   samples = recordingState.waveSamples
                // }
                recordingInfo.withLock { recordingInfo in
                  recordingInfo.duration = recordingState.duration
                }
              }
            }

            try await group.waitForAll()
          }
        } catch: { error, send in
          logs.error("Error while starting recording: \(error)")
          await send(.delegate(.didFinish(.failure(error))))
        }

      case .saveButtonTapped:
        state.mode = .saving

        return .run { [state] send in
          generateImpact()
          await transcriptionStream.stopRecording()
          do {
            guard FileManager.default.fileExists(atPath: state.recordingInfo.fileURL.path) else {
              throw NSError(
                domain: "Recording",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The recording audio could not be saved. Please try recording again."]
              )
            }
            let values = try state.recordingInfo.fileURL.resourceValues(forKeys: [.fileSizeKey])
            guard values.fileSize.map({ $0 > 0 }) == true else {
              throw NSError(
                domain: "Recording",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The recording audio could not be saved. Please try recording again."]
              )
            }
            await send(.delegate(.didFinish(.success(state))))
          } catch {
            await send(.delegate(.didFinish(.failure(error))))
          }
        }

      case .pauseButtonTapped:
        state.mode = .paused

        return .run { _ in
          generateImpact()
          await transcriptionStream.pauseRecording()
        }

      case .continueButtonTapped:
        state.mode = .recording

        return .run { _ in
          generateImpact()
          await transcriptionStream.resumeRecording()
        }

      case .deleteButtonTapped:
        state.mode = .removing

        return .run { [state] send in
          generateImpact()
          await transcriptionStream.stopRecording()
          try? FileManager.default.removeItem(at: state.recordingInfo.fileURL)
          await send(.delegate(.didCancel))
        }

      case .toggleModelLoadingInfo:
        state.isModelLoadingInfoPresented.toggle()
        return .none
      }
    }
  }

  func generateImpact() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }
}

// MARK: - RecordingView

/// A view that displays the recording waveform and current time.
struct RecordingView: View {
  @Bindable var store: StoreOf<Recording>

  var currentTime: String {
    dateComponentsFormatter.string(from: store.recordingInfo.duration) ?? ""
  }

  var body: some View {
    Group {
      VStack(spacing: .grid(3)) {
        liveTranscriptionView()

        if !store.isLiveTranscriptionEnabled {
          WaveformLiveCanvas(samples: store.state.samples, configuration: Waveform.Configuration(
            backgroundColor: .clear,
            style: .striped(.init(color: UIColor(Color.DS.Text.base), width: 2, spacing: 4, lineCap: .round)),
            damping: .init(percentage: 0.125, sides: .both),
            scale: DSScreen.scale,
            verticalScalingFactor: 0.95,
            shouldAntialias: true
          ))
          .frame(maxWidth: .infinity)
        }

        Text(currentTime)
          .foregroundColor(.DS.Text.accent)
          .textStyle(.navigationTitle)
          .monospaced()
      }
    }
    .task {
      await store.send(.onTask).finish()
    }
  }

  /// A view that displays live transcription of the recording.
  ///
  /// - Parameter recording: The current recording state.
  @ViewBuilder
  private func liveTranscriptionView() -> some View {
    VStack(spacing: .grid(2)) {
      if let progress = store.liveTranscriptionState?.modelProgress {
        modelLoadingView(progress: progress)
      }
      transcribingView(recording: store.state)

      Spacer()
    }
  }

  /// A view that displays the model loading progress.
  ///
  /// - Parameter progress: The current progress of the model loading.
  @ViewBuilder
  private func modelLoadingView(progress: Double) -> some View {
    LabeledContent {
      Text("\(Int(progress * 100)) %")
        .foregroundColor(.DS.Text.base)
        .textStyle(.body)
    } label: {
      VStack {
        HStack {
          Label("Model Loading", systemImage: "info.circle")
            .foregroundColor(.DS.Text.base)
            .textStyle(.body)

          Button(action: {
            store.send(.toggleModelLoadingInfo)
          }) {
            Image(systemName: "exclamationmark.circle.fill")
              .foregroundColor(.blue)
          }
          .popover(isPresented: $store.isModelLoadingInfoPresented, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
            Text("The model is currently loading. This process may take a few moments.")
          }
        }

        // if let tokensPerSecond = store.recordingInfo.transcription?.timings.tokensPerSecond {
        //   LabeledContent {
        //     Text(String(format: "%.2f", tokensPerSecond))
        //   } label: {
        //     Label("Tokens/Second", systemImage: "speedometer")
        //   }
        //   .textStyle(.footnote)
        // }
      }
    }
    .padding(.grid(4))
    .cardStyle()
    .fixedSize(horizontal: true, vertical: true)
  }

  /// A view that displays the transcribed text of the recording.
  ///
  /// - Parameters:
  ///   - recording: The current recording state.
  ///   - text: The transcribed text.
  @ViewBuilder
  private func transcribingView(recording: Recording.State) -> some View {
    ScrollView(showsIndicators: false) {
      Text(transcriptionDisplayText(for: recording))
        .textStyle(.body)
        .foregroundColor(recording.recordingInfo.text.isEmpty ? .DS.Text.subdued : .DS.Text.base)
        .lineLimit(nil)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, .grid(2))
        .padding(.horizontal, .grid(4))
    }
  }

  private func transcriptionDisplayText(for recording: Recording.State) -> String {
    guard recording.isLiveTranscriptionEnabled,
          recording.recordingInfo.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return recording.recordingInfo.text
    }

    switch recording.liveTranscriptionState {
    case .transcribing:
      return "Listening…"
    case .modelLoading:
      return "Preparing the on-device model…"
    case nil:
      return "Starting live transcription…"
    }
  }
}
