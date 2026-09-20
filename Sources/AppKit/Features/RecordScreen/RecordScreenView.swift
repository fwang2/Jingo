import AudioProcessing
import Common
import ComposableArchitecture
import Inject
import Pow
import SwiftUI

// MARK: - RecordScreen

@Reducer
struct RecordScreen {
  @ObservableState
  struct State: Equatable, Then {
    @Presents var alert: AlertState<Action.Alert>?
    var micSelector = MicSelector.State()
    var recordingControls = RecordingControls.State()
  }

  enum Action: Equatable, BindableAction {
    case binding(BindingAction<State>)
    case micSelector(MicSelector.Action)
    case recordingControls(RecordingControls.Action)
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)

    enum Alert: Equatable {}

    enum Delegate: Equatable {
      case newRecordingCreated(RecordingInfo)
    }
  }

  var body: some Reducer<State, Action> {
    BindingReducer()

    Scope(state: \.micSelector, action: \.micSelector) {
      MicSelector()
    }

    Scope(state: \.recordingControls, action: \.recordingControls) {
      RecordingControls()
    }

    Reduce<State, Action> { state, action in
      switch action {
      case let .recordingControls(.recording(.delegate(.didFinish(.success(recording))))):
        var recordingInfo = recording.recordingInfo
        if recording.isLiveTranscriptionEnabled {
          recordingInfo.transcription?.status = .done(Date())
        }

        return .send(.delegate(.newRecordingCreated(recordingInfo)))

      case let .recordingControls(.recording(.delegate(.didFinish(.failure(error))))):
        state.alert = AlertState {
          TextState("Voice recording failed.")
        } actions: {} message: {
          TextState(error.localizedDescription)
        }
        return .none

      case .recordingControls:
        return .none

      case .micSelector:
        return .none

      case .delegate:
        return .none

      case .binding:
        return .none

      case .alert:
        return .none

      }
    }
    .ifLet(\.$alert, action: \.alert)
  }
}

// MARK: - RecordScreenView

struct RecordScreenView: View {
  @Bindable var store: StoreOf<RecordScreen>

  var body: some View {
    Group {
      VStack(spacing: .grid(6)) {
        MicSelectorView(store: store.scope(state: \.micSelector, action: \.micSelector))

        Spacer()

        RecordingControlsView(store: store.scope(state: \.recordingControls, action: \.recordingControls))
      }
      .padding(.grid(4))
      .padding(.horizontal, .grid(2))
      .padding(.bottom, .grid(10))
      .alert($store.scope(state: \.alert, action: \.alert))
    }
  }

}
