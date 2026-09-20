import AudioProcessing
import Common
import ComposableArchitecture
import DSWaveformImage
import DSWaveformImageViews
import Foundation
import Inject
import Popovers
import SwiftUI

// MARK: - RecordingControls

/// A reducer that manages the state and actions related to recording controls.
@Reducer
struct RecordingControls {
  /// The state of the recording controls.
  @ObservableState
  struct State: Equatable {
    /// Permissions for the recorder.
    enum RecorderPermission {
      case allowed
      case denied
      case undetermined
    }

    var alert: AlertState<Action>?
    var recording: Recording.State?
    var audioRecorderPermission = RecorderPermission.undetermined
  }

  /// Actions that can be performed on the recording controls.
  enum Action: Equatable, BindableAction {
    case binding(BindingAction<State>)
    case recording(Recording.Action)
    case recordButtonTapped
    case openSettingsButtonTapped
  }

  @Dependency(\.audioSession.requestRecordPermission) var requestRecordPermission
  @Dependency(\.openSettings) var openSettings
  @Dependency(\.date) var date
  @Dependency(\.continuousClock) var clock
  @Dependency(\.uuid) var uuid

  /// Identifiers for cancellable effects.
  enum CancelID: Hashable { case recording }

  /// The body of the reducer, defining how state changes in response to actions.
  var body: some ReducerOf<Self> {
    BindingReducer()

    Reduce<State, Action> { state, action in
      switch action {
      case .recordButtonTapped where state.audioRecorderPermission == .undetermined:
        return .run { send in
          let permission = await requestRecordPermission()
          await send(.set(\.audioRecorderPermission, permission ? .allowed : .denied))
          if permission {
            await send(.set(\.recording, createNewRecording()))
          }
        }

      case .recordButtonTapped where state.audioRecorderPermission == .allowed:
        state.recording = createNewRecording()
        return .none

      case .recordButtonTapped:
        assertionFailure("Can't press record button when permission is denied")
        return .none

      case .recording(.delegate(.didCancel)):
        state.recording = nil
        return .cancel(id: CancelID.recording)

      case .recording(.delegate(.didFinish(.success))):
        state.recording = nil
        return .cancel(id: CancelID.recording)

      case .recording(.delegate(.didFinish(.failure))):
        state.recording = nil
        return .cancel(id: CancelID.recording)

      case .recording:
        return .none

      case .openSettingsButtonTapped:
        return .run { _ in
          await openSettings()
        }

      case .binding:
        return .none
      }
    }
    .ifLet(\.recording, action: \.recording) { Recording() }
  }

  private func createNewRecording() -> Recording.State {
    let newInfo = RecordingInfo(id: uuid().uuidString, date: date.now)

    @Shared(.settings) var settings
    #if APPSTORE
      @Shared(.premiumFeatures) var premiumFeatures
      let isLiveTranscriptionEnabled = premiumFeatures.liveTranscriptionIsPurchased == true && settings.isLiveTranscriptionEnabled
    #else
      let isLiveTranscriptionEnabled = settings.isLiveTranscriptionEnabled
    #endif

    return Recording.State(recordingInfo: newInfo, isLiveTranscriptionEnabled: isLiveTranscriptionEnabled)
  }

  /// An alert state for microphone permission denial.
  private var micPermissionAlert: AlertState<Action> {
    AlertState {
      TextState("Permission is required to record voice.")
    } actions: {
      ButtonState(action: .openSettingsButtonTapped) {
        TextState("Open Settings")
      }
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
    } message: {
      TextState("Please enable microphone access in Settings.")
    }
  }
}

// MARK: - RecordingControlsView

/// A view that provides controls for recording audio.
struct RecordingControlsView: View {
  @Bindable var store: StoreOf<RecordingControls>

  var body: some View {
    Group {
      if let recordingStore = store.scope(state: \.recording, action: \.recording) {
        RecordingView(store: recordingStore)
      }

      if store.recording == nil, store.audioRecorderPermission == .denied {
        VStack(spacing: .grid(2)) {
          Text("Recording requires microphone access.")
            .multilineTextAlignment(.center)
          Button("Open Settings") {
            store.send(.openSettingsButtonTapped)
          }
        }
      } else if store.recording != nil {
        HStack(spacing: .grid(8)) {
          if store.recording?.mode == .paused {
            Button { store.send(.recording(.deleteButtonTapped), animation: .showHide()) }
              label: {
                Image(systemName: "multiply")
                  .textStyle(.navigationTitle)
                  .frame(width: 50, height: 50)
                  .containerShape(Rectangle())
              }
              .transition(.move(edge: .trailing).combined(with: .opacity))
          }

          ZStack {
            if store.recording?.mode == .recording {
              Button { store.send(.recording(.pauseButtonTapped), animation: .showHide()) } label: {
                Circle()
                  .fill(RadialGradient.accent)
                  .shadow(color: .DS.Background.accent.opacity(0.5), radius: 20)
                  .overlay(Image(systemName: "pause.fill").textStyle(.headline))
              }
              .recordButtonStyle()
            } else if store.recording?.mode == .paused {
              Button { store.send(.recording(.continueButtonTapped), animation: .showHide()) } label: {
                Circle()
                  .fill(RadialGradient.accent)
                  .overlay(Image(systemName: "mic").textStyle(.headline))
              }
              .recordButtonStyle()
            }
          }
          .frame(width: 70, height: 70)

          if store.recording?.mode == .paused {
            Button { store.send(.recording(.saveButtonTapped), animation: .showHide()) }
              label: {
                Image(systemName: "checkmark")
                  .textStyle(.navigationTitle)
                  .frame(width: 50, height: 50)
                  .containerShape(Rectangle())
              }
              .transition(.move(edge: .leading).combined(with: .opacity))
          }
        }
        .padding(.horizontal, .grid(3))
      }
    }
  }
}
