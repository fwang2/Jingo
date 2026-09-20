import AudioProcessing
import Common
import ComposableArchitecture
import Inject
import SwiftUI

// MARK: - RecordingDetails

@Reducer
struct RecordingDetails {
  enum DisplayMode: Equatable {
    case text, timeline
  }

  struct TimelineItem: Equatable, Identifiable {
    var id: Duration {
      startTime
    }

    var text: String
    var startTime: Duration
    var endTime: Duration
    var speakerID: String?
    var speakerName: String?
    var speakerColorIndex: Int?
  }

  @ObservableState
  struct State: Equatable {
    var recordingCard: RecordingCard.State
    @Shared var displayMode: DisplayMode
    @Shared(.speakerProfiles) var speakerProfiles: [SpeakerProfile]

    @Presents var alert: AlertState<Action.Alert>?
    @Presents var actionSheet: RecordingActionsSheet.State?

    var timeline: [TimelineItem] {
      let segments = recordingCard.recording.transcription?.segments ?? []
      let speakerIDs = orderedSpeakerIDs(in: segments)
      return segments.map {
        let colorIndex = $0.speaker.flatMap(speakerIDs.firstIndex)
        return TimelineItem(
          text: $0.text,
          startTime: Duration.milliseconds($0.startTimeMS),
          endTime: Duration.milliseconds($0.endTimeMS),
          speakerID: $0.speaker,
          speakerName: $0.speaker.map { speakerID in
            recordingCard.recording.speakerNames[speakerID]
              ?? "Speaker \((speakerIDs.firstIndex(of: speakerID) ?? 0) + 1)"
          },
          speakerColorIndex: colorIndex
        )
      }
    }

    var hasSpeakerAttribution: Bool {
      timeline.contains { $0.speakerID != nil }
    }

    var shareAudioFileURL: URL {
      recordingCard.recording.fileURL
    }

    init(recordingCard: RecordingCard.State, displayMode: DisplayMode = .text) {
      self.recordingCard = recordingCard
      _displayMode = Shared(value: displayMode)
    }

    private func orderedSpeakerIDs(in segments: [Segment]) -> [String] {
      segments.reduce(into: []) { result, segment in
        if let speaker = segment.speaker, !result.contains(speaker) {
          result.append(speaker)
        }
      }
    }
  }

  enum Action: Equatable, BindableAction {
    case binding(BindingAction<State>)
    case recordingCard(RecordingCard.Action)
    case delete
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)
    case actionSheet(PresentationAction<RecordingActionsSheet.Action>)
    case presentActionSheet
    case speakerNameChanged(id: String, name: String)

    enum Alert: Hashable {
      case deleteDialogConfirmed
    }

    enum Delegate: Hashable {
      case deleteDialogConfirmed
    }
  }

  var body: some Reducer<State, Action> {
    BindingReducer()

    Scope(state: \.recordingCard, action: \.recordingCard) {
      RecordingCard()
    }

    Reduce<State, Action> { state, action in
      switch action {
      case .binding:
        return .none

      case .recordingCard:
        return .none

      case .delete:
        state.alert = AlertState {
          TextState("Confirmation")
        } actions: {
          ButtonState(role: .destructive, action: .deleteDialogConfirmed) {
            TextState("Delete")
          }
        } message: {
          TextState("Are you sure you want to delete this recording?")
        }
        return .none

      case .alert(.presented(.deleteDialogConfirmed)):
        return .send(.delegate(.deleteDialogConfirmed))

      case .alert:
        return .none

      case .delegate:
        return .none

      case .presentActionSheet:
        state.actionSheet = RecordingActionsSheet.State(
          displayMode: state.$displayMode,
          isTranscribing: state.recordingCard.$recording.isTranscribing,
          transcription: state.recordingCard.$recording.transcription,
          audioFileURL: state.recordingCard.$recording.fileURL
        )
        return .none

      case let .speakerNameChanged(id, name):
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var embedding: [Float]?
        var linkedProfileID: UUID?
        state.recordingCard.$recording.withLock { recording in
          embedding = recording.transcription?.speakerEmbeddings[id]
          linkedProfileID = recording.transcription?.speakerProfileIDs[id]
          if trimmedName.isEmpty {
            recording.speakerNames.removeValue(forKey: id)
            recording.transcription?.speakerNames.removeValue(forKey: id)
            recording.transcription?.speakerProfileIDs.removeValue(forKey: id)
          } else {
            recording.speakerNames[id] = trimmedName
            recording.transcription?.speakerNames[id] = trimmedName
          }
        }

        if !trimmedName.isEmpty, let embedding {
          var enrolledProfileID: UUID?
          state.$speakerProfiles.withLock { profiles in
            enrolledProfileID = SpeakerProfileMatcher.enroll(
              name: trimmedName,
              embedding: embedding,
              linkedProfileID: linkedProfileID,
              profiles: &profiles
            )
          }
          if let enrolledProfileID {
            state.recordingCard.$recording.withLock { recording in
              recording.transcription?.speakerProfileIDs[id] = enrolledProfileID
            }
          }
        }
        return .none

      case .actionSheet(.presented(.delete)):
        return .send(.delete)

      case .actionSheet(.presented(.restartTranscription)):
        return .send(.recordingCard(.transcribeButtonTapped))

      case .actionSheet:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
    .ifLet(\.$actionSheet, action: \.actionSheet) {
      RecordingActionsSheet()
    }
  }
}

// MARK: - RecordingDetailsView

struct RecordingDetailsView: View {
  enum Field: Int, CaseIterable {
    case title, text
  }

  @FocusState private var focusedField: Field?
  @State private var renamingSpeakerID: String?
  @State private var speakerNameDraft = ""
  @Bindable var store: StoreOf<RecordingDetails>

  var body: some View {
    VStack(spacing: .grid(4)) {
      headerView
      transcriptionView
      waveformProgressView
      playButtonView
    }
    .background(Color.DS.Background.primary)
    .toolbar {
      ToolbarItem(placement: .keyboard) {
        doneButton
      }
      ToolbarItem(placement: .bottomBar) {
        actionSheetButton
      }
    }

    .alert($store.scope(state: \.alert, action: \.alert))
    .alert("Rename Speaker", isPresented: renameSpeakerIsPresented) {
      TextField("Name", text: $speakerNameDraft)
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        guard let speakerID = renamingSpeakerID else { return }
        store.send(.speakerNameChanged(id: speakerID, name: speakerNameDraft))
        renamingSpeakerID = nil
      }
    } message: {
      Text("This name will also help recognize the speaker in future recordings.")
    }
    .sheet(item: $store.scope(state: \.actionSheet, action: \.actionSheet)) { store in
      RecordingActionsSheetView(store: store)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
  }

  private var headerView: some View {
    RecordingDetailsHeaderView(
      store: store,
      focusedField: _focusedField
    )
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var waveformProgressView: some View {
    WaveformProgressView(
      store: store.scope(
        state: \.recordingCard.playerControls.waveform,
        action: \.recordingCard.playerControls.waveform
      )
    )
    .padding(.horizontal, .grid(4))
  }

  private var playButtonView: some View {
    PlayButton(isPlaying: store.recordingCard.playerControls.isPlaying) {
      store.send(.recordingCard(.playerControls(.playButtonTapped)), animation: .bouncy)
    }
  }

  private var doneButton: some View {
    Button("Done") {
      focusedField = nil
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }

  private var transcriptionView: some View {
    ScrollView {
      switch store.displayMode {
      case .text:
        textTranscriptionView

      case .timeline:
        timelineTranscriptionView
      }
    }
    // .scrollAnchor(id: 1, valueToTrack: store.recordingCard.transcription, anchor: store.recordingCard.recording.isTranscribing ? .bottom : .zero)
    .applyVerticalEdgeSofteningMask()
  }

  private var textTranscriptionView: some View {
    Group {
      if store.hasSpeakerAttribution {
        LazyVStack(spacing: .grid(3)) {
          ForEach(store.timeline) { item in
            speakerTurnView(item, showsTimeRange: false)
          }
        }
      } else {
        Text(store.recordingCard.transcription)
          .foregroundColor(store.recordingCard.recording.isTranscribing ? .DS.Text.subdued : .DS.Text.base)
          .textStyle(.body)
          .lineLimit(nil)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .padding(.vertical, .grid(2))
    .padding(.horizontal, .grid(4))
    // .id(1)
  }

  private var timelineTranscriptionView: some View {
    LazyVStack {
      ForEach(store.timeline) { item in
        speakerTurnView(item, showsTimeRange: true)
      }
    }
    .padding(.horizontal, .grid(4))
    // .id(1)
  }

  private func speakerTurnView(
    _ item: RecordingDetails.TimelineItem,
    showsTimeRange: Bool
  ) -> some View {
    let color = speakerColor(at: item.speakerColorIndex)
    return VStack(alignment: .leading, spacing: .grid(2)) {
      HStack(spacing: .grid(2)) {
        if let speakerID = item.speakerID, let speakerName = item.speakerName {
          Button {
            beginRenaming(speakerID: speakerID, currentName: speakerName)
          } label: {
            Label(speakerName, systemImage: "person.fill")
              .font(.caption.weight(.semibold))
              .foregroundStyle(color)
              .padding(.horizontal, .grid(2))
              .padding(.vertical, .grid(1))
              .background(color.opacity(0.15), in: Capsule())
          }
          .buttonStyle(.plain)
          .accessibilityHint("Rename speaker")
        }

        if showsTimeRange {
          Text(
            "\(item.startTime.formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 2, fractionalSecondsLength: 2)))) – \(item.endTime.formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 2, fractionalSecondsLength: 2))))"
          )
          .foregroundColor(.DS.Text.subdued)
          .textStyle(.caption)
        }
      }

      Text(item.text)
        .foregroundColor(.DS.Text.base)
        .textStyle(.body)
        .lineLimit(nil)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .multilineTextAlignment(.leading)
    .padding(.vertical, .grid(2))
    .padding(.horizontal, store.hasSpeakerAttribution ? .grid(3) : 0)
    .background(
      color.opacity(item.speakerID == nil ? 0 : 0.07),
      in: RoundedRectangle(cornerRadius: .grid(3))
    )
  }

  private var renameSpeakerIsPresented: Binding<Bool> {
    Binding(
      get: { renamingSpeakerID != nil },
      set: {
        if !$0 {
          renamingSpeakerID = nil
          speakerNameDraft = ""
        }
      }
    )
  }

  private func beginRenaming(speakerID: String, currentName: String) {
    speakerNameDraft = currentName
    renamingSpeakerID = speakerID
  }

  private func speakerColor(at index: Int?) -> Color {
    let colors: [Color] = [
      .DS.primary02,
      .DS.accents03,
      .DS.accents05,
      .DS.code03,
      .DS.code04,
      .cyan,
    ]
    guard let index else { return .DS.Text.subdued }
    return colors[index % colors.count]
  }

  private var actionSheetButton: some View {
    Button(action: { store.send(.presentActionSheet) }) {
      Image(systemName: "ellipsis.circle")
        .foregroundColor(.DS.Text.base)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

// MARK: - RecordingDetailsHeaderView

struct RecordingDetailsHeaderView: View {
  @Bindable var store: StoreOf<RecordingDetails>
  @FocusState var focusedField: RecordingDetailsView.Field?

  var body: some View {
    VStack(spacing: .grid(2)) {
      TextField(
        "Untitled",
        text: Binding(store.recordingCard.$recording).title,
        axis: .vertical
      )
      .focused($focusedField, equals: .title)
      .textStyle(.body)

      Text(store.recordingCard.recording.date.formatted(date: .abbreviated, time: .shortened))
        .textStyle(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)

      // if let timings = store.recordingCard.recording.transcription?.timings {
      //   VStack(alignment: .leading, spacing: .grid(1)) {
      //     LabeledContent {
      //       Text(String(format: "%.2f", timings.tokensPerSecond))
      //     } label: {
      //       Label("Tokens/Second", systemImage: "speedometer")
      //     }

      //     LabeledContent {
      //       Text(String(format: "%.2f", timings.fullPipeline))
      //     } label: {
      //       Label("Full Pipeline (s)", systemImage: "clock")
      //     }
      //   }
      //   .textStyle(.footnote)
      // }

      if let error = store.recordingCard.recording.transcription?.status.errorMessage {
        Text("Last transcription failed")
          .textStyle(.error)

        Text(error)
          .textStyle(.error)
      } else {
        TranscriptionControlsView(store: store.scope(state: \.recordingCard, action: \.recordingCard), queueInfo: nil)
      }
    }
    .padding(.horizontal, .grid(4))
  }
}
