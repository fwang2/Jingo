import AudioProcessing
import Common
import ComposableArchitecture
import Foundation
import SwiftUI

// MARK: - SpeakerEnrollment

@Reducer
struct SpeakerEnrollment {
  @ObservableState
  struct State: Equatable {
    @Shared(.speakerProfiles) var speakerProfiles: [SpeakerProfile]

    let profileID: UUID?
    var name: String
    var recordingDuration: TimeInterval = 0
    var isRecording = false
    var isProcessing = false
    var errorMessage: String?
    var sampleURL: URL?

    init(profile: SpeakerProfile? = nil) {
      profileID = profile?.id
      name = profile?.name ?? ""
    }

    var title: String {
      profileID == nil ? "Add Speaker" : "Add Voice Sample"
    }

    var canStartRecording: Bool {
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !isRecording
        && !isProcessing
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case cancelButtonTapped
    case delegate(Delegate)
    case enrollmentFinished(Result<[Float], EquatableError>)
    case onDisappear
    case recordButtonTapped
    case recordingFailed(EquatableError)
    case recordingUpdated(TimeInterval)
    case stopButtonTapped

    enum Delegate: Equatable {
      case cancel
      case saved
    }
  }

  private enum CancelID: Hashable {
    case recording
    case processing
  }

  @Dependency(RecordingTranscriptionStream.self) private var transcriptionStream
  @Dependency(SpeakerDiarizationClient.self) private var speakerDiarization

  var body: some Reducer<State, Action> {
    BindingReducer()

    Reduce { state, action in
      switch action {
      case .binding:
        state.errorMessage = nil
        return .none

      case .recordButtonTapped:
        do {
          _ = try SpeakerProfileMatcher.validatedName(
            state.name,
            excluding: state.profileID,
            profiles: state.speakerProfiles
          )
        } catch {
          state.errorMessage = error.localizedDescription
          return .none
        }

        let sampleURL = FileManager.default.temporaryDirectory
          .appendingPathComponent("jingo-speaker-sample-\(UUID().uuidString).caf")
        state.sampleURL = sampleURL
        state.recordingDuration = 0
        state.isRecording = true
        state.errorMessage = nil

        return .run { send in
          do {
            for try await recordingState in await transcriptionStream.startRecording(sampleURL) {
              await send(.recordingUpdated(recordingState.duration))
            }
          } catch {
            await send(.recordingFailed(error.equatable))
          }
        }
        .cancellable(id: CancelID.recording, cancelInFlight: true)

      case let .recordingUpdated(duration):
        state.recordingDuration = duration
        return .none

      case let .recordingFailed(error):
        state.isRecording = false
        state.isProcessing = false
        state.errorMessage = error.localizedDescription
        let sampleURL = state.sampleURL
        state.sampleURL = nil
        return .run { _ in
          if let sampleURL {
            try? FileManager.default.removeItem(at: sampleURL)
          }
        }

      case .stopButtonTapped:
        guard let sampleURL = state.sampleURL else { return .none }
        state.isRecording = false
        state.isProcessing = true
        state.errorMessage = nil

        return .run { send in
          await transcriptionStream.stopRecording()
          defer { try? FileManager.default.removeItem(at: sampleURL) }
          do {
            let result = try await speakerDiarization.diarize(sampleURL) { _ in }
            let embedding = try result.enrollmentEmbedding()
            await send(.enrollmentFinished(.success(embedding)))
          } catch {
            await send(.enrollmentFinished(.failure(error.equatable)))
          }
        }
        .cancellable(id: CancelID.processing, cancelInFlight: true)

      case let .enrollmentFinished(.success(embedding)):
        state.isProcessing = false
        state.sampleURL = nil
        let name: String
        do {
          name = try SpeakerProfileMatcher.validatedName(
            state.name,
            excluding: state.profileID,
            profiles: state.speakerProfiles
          )
        } catch {
          state.errorMessage = error.localizedDescription
          return .none
        }

        var enrolledProfileID: UUID?
        state.$speakerProfiles.withLock { profiles in
          enrolledProfileID = SpeakerProfileMatcher.enroll(
            name: name,
            embedding: embedding,
            linkedProfileID: state.profileID,
            profiles: &profiles
          )
        }
        guard enrolledProfileID != nil else {
          state.errorMessage = SpeakerProfileEnrollmentError.missingEmbedding.localizedDescription
          return .none
        }
        return .send(.delegate(.saved))

      case let .enrollmentFinished(.failure(error)):
        state.isProcessing = false
        state.sampleURL = nil
        state.errorMessage = error.localizedDescription
        return .none

      case .cancelButtonTapped:
        let sampleURL = state.sampleURL
        state.sampleURL = nil
        state.isRecording = false
        state.isProcessing = false
        return .merge(
          .cancel(id: CancelID.recording),
          .cancel(id: CancelID.processing),
          .run { send in
            await transcriptionStream.stopRecording()
            if let sampleURL {
              try? FileManager.default.removeItem(at: sampleURL)
            }
            await send(.delegate(.cancel))
          }
        )

      case .onDisappear:
        let sampleURL = state.sampleURL
        state.sampleURL = nil
        state.isRecording = false
        return .merge(
          .cancel(id: CancelID.recording),
          .cancel(id: CancelID.processing),
          .run { _ in
            await transcriptionStream.stopRecording()
            if let sampleURL {
              try? FileManager.default.removeItem(at: sampleURL)
            }
          }
        )

      case .delegate:
        return .none
      }
    }
  }
}

// MARK: - SpeakerEnrollmentView

struct SpeakerEnrollmentView: View {
  @Bindable var store: StoreOf<SpeakerEnrollment>

  var body: some View {
    NavigationStack {
      Form {
        Section("Speaker") {
          TextField("Name", text: $store.name)
            .textInputAutocapitalization(.words)
            .disabled(store.profileID != nil || store.isRecording || store.isProcessing)
        }

        Section {
          VStack(spacing: .grid(3)) {
            Image(systemName: store.isRecording ? "waveform.circle.fill" : "person.wave.2")
              .font(.system(size: 44))
              .foregroundStyle(store.isRecording ? Color.red : Color.accentColor)

            Text(statusTitle)
              .font(.headline)

            Text(statusDetail)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)

            if store.isProcessing {
              ProgressView()
            } else if store.isRecording {
              Button("Stop and Save Sample", systemImage: "stop.fill") {
                store.send(.stopButtonTapped)
              }
              .buttonStyle(.borderedProminent)
              .tint(.red)
            } else {
              Button("Record Voice Sample", systemImage: "mic.fill") {
                store.send(.recordButtonTapped)
              }
              .buttonStyle(.borderedProminent)
              .disabled(!store.canStartRecording)
            }
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, .grid(3))
        }

        if let errorMessage = store.errorMessage {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle(store.title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            store.send(.cancelButtonTapped)
          }
        }
      }
      .interactiveDismissDisabled(store.isRecording || store.isProcessing)
      .onDisappear {
        store.send(.onDisappear)
      }
    }
  }

  private var statusTitle: String {
    if store.isProcessing {
      return "Creating voice profile…"
    }
    if store.isRecording {
      return Duration.seconds(store.recordingDuration).formatted(.time(pattern: .minuteSecond))
    }
    return "Record 10–20 seconds"
  }

  private var statusDetail: String {
    if store.isProcessing {
      return "The sample is processed entirely on this device."
    }
    if store.isRecording {
      return "Speak naturally. Only the person being enrolled should talk."
    }
    return "Use a quiet room and speak naturally. You can add more samples later to improve recognition."
  }
}
