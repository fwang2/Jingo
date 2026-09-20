import AudioProcessing
import Common
import ComposableArchitecture
import IdentifiedCollections
import Inject
import Popovers
import SwiftUI

// MARK: - SettingsScreen

@Reducer
struct SettingsScreen {
  @ObservableState
  struct State: Equatable {
    @Shared(.settings) var settings: Settings
    @Shared(.recordings) var recordings: IdentifiedArrayOf<RecordingInfo>
    @Shared(.speakerProfiles) var speakerProfiles: [SpeakerProfile]

    var modelSelector: ModelSelector.State = .init()
    var premiumFeaturesSection: PremiumFeaturesSection.State = .init()

    let availableLanguages: [String] = ["Auto"]
    var appVersion: String = ""
    var buildNumber: String = ""
    var freeSpace: String = ""
    var takenSpace: String = ""
    var takenSpacePercentage: Double = 0

    @Shared(.isICloudSyncInProgress) var isICloudSyncInProgress: Bool
    var isDebugLogPresented = false
    var isModelSelectorPresented = false

    @Presents var alert: AlertState<Action.Alert>?
    @Presents var speakerEnrollment: SpeakerEnrollment.State?

    var selectedLanguageIndex: Int {
      get { settings.voiceLanguage.flatMap { availableLanguages.firstIndex(of: $0) } ?? 0 }
      set { $settings.withLock { $0.voiceLanguage = newValue == 0 ? nil : availableLanguages[safe: newValue] } }
    }

    init() {}
  }

  enum Action: BindableAction {
    case alert(PresentationAction<Alert>)
    case binding(BindingAction<State>)
    case addSpeakerSampleTapped(UUID)
    case addSpeakerTapped
    case forgetSpeakerTapped(UUID)
    case renameSpeakerSubmitted(UUID, String)
    case speakerEnrollment(PresentationAction<SpeakerEnrollment.Action>)
    case task

    case modelSelector(ModelSelector.Action)
    case premiumFeaturesSection(PremiumFeaturesSection.Action)

    case deleteStorageTapped
    case deleteAllModelsTapped
    case openGitHub
    case openPersonalWebsite
    case rateAppTapped
    case reportBugTapped
    case showError(EquatableError)
    case suggestFeatureTapped
    case updateInfo
    case iCloudSyncToggled(Bool)

    enum Alert: Equatable {
      case deleteStorageDialogConfirmed
      case deleteAllModelsDialogConfirmed
    }
  }

  @Dependency(\.openURL) var openURL: OpenURLEffect
  @Dependency(\.build) var build: BuildClient
  @Dependency(StorageClient.self) var storage: StorageClient

  var body: some Reducer<State, Action> {
    BindingReducer()

    Scope(state: \.modelSelector, action: \.modelSelector) {
      ModelSelector()
    }

    Scope(state: \.premiumFeaturesSection, action: \.premiumFeaturesSection) {
      PremiumFeaturesSection()
    }

    Reduce<State, Action> { state, action in
      switch action {
      case .binding:
        return .none

      case .addSpeakerTapped:
        state.speakerEnrollment = SpeakerEnrollment.State()
        return .none

      case let .addSpeakerSampleTapped(profileID):
        guard let profile = state.speakerProfiles.first(where: { $0.id == profileID }) else {
          return .none
        }
        state.speakerEnrollment = SpeakerEnrollment.State(profile: profile)
        return .none

      case let .renameSpeakerSubmitted(profileID, name):
        do {
          var updatedName = ""
          try state.$speakerProfiles.withLock { profiles in
            updatedName = try SpeakerProfileMatcher.rename(
              profileID: profileID,
              to: name,
              profiles: &profiles
            )
          }
          state.$recordings.withLock { recordings in
            for index in recordings.indices {
              let linkedSpeakerIDs = recordings[index].transcription?.speakerProfileIDs
                .filter { $0.value == profileID }
                .map(\.key) ?? []
              for speakerID in linkedSpeakerIDs {
                recordings[index].speakerNames[speakerID] = updatedName
                recordings[index].transcription?.speakerNames[speakerID] = updatedName
              }
            }
          }
        } catch {
          state.alert = .error(error.equatable)
        }
        return .none

      case let .forgetSpeakerTapped(profileID):
        state.$speakerProfiles.withLock { profiles in
          profiles.removeAll { $0.id == profileID }
        }
        state.$recordings.withLock { recordings in
          for index in recordings.indices {
            guard var profileIDs = recordings[index].transcription?.speakerProfileIDs else {
              continue
            }
            profileIDs = profileIDs.filter { $0.value != profileID }
            recordings[index].transcription?.speakerProfileIDs = profileIDs
          }
        }
        return .none

      case .speakerEnrollment(.presented(.delegate)):
        state.speakerEnrollment = nil
        return .none

      case .speakerEnrollment:
        return .none

      case .modelSelector:
        return .none

      case .premiumFeaturesSection:
        return .none

      case .task:
        updateInfo(state: &state)
        return .none

      case .updateInfo:
        updateInfo(state: &state)
        return .send(.modelSelector(.reloadModels))

      case .openGitHub:
        return .run { _ in
          await openURL(build.githubURL())
        }

      case .openPersonalWebsite:
        return .run { _ in
          await openURL(build.personalWebsiteURL())
        }

      case .deleteStorageTapped:
        state.alert = .deleteStorage
        return .none

      case .deleteAllModelsTapped:
        state.alert = .deleteAllModels
        return .none

      case .alert(.presented(.deleteStorageDialogConfirmed)):
        state.$settings.withLock { $0.selectedModelName = Model.defaultModelName }
        return .run { send in
          try await storage.deleteStorage()
          await send(.updateInfo)
        } catch: { error, send in
          await send(.showError(error.equatable))
        }

      case .alert(.presented(.deleteAllModelsDialogConfirmed)):
        state.$settings.withLock { $0.selectedModelName = Model.defaultModelName }
        return .run { send in
          try? FileManager.default.removeItem(at: TranscriptionStream.modelDirURL)
          try? FileManager.default.removeItem(at: .documentsDirectory.appendingPathComponent("models"))
          await send(.updateInfo)
          await send(.modelSelector(.reloadModels))
        } catch: { error, send in
          await send(.showError(error.equatable))
        }

      case let .showError(error):
        state.alert = .error(error)
        return .none

      case .rateAppTapped:
        return .run { _ in
          await openURL(build.appStoreReviewURL())
        }

      case .reportBugTapped:
        return .run { _ in
          await openURL(build.bugReportURL())
        }

      case .suggestFeatureTapped:
        return .run { _ in
          await openURL(build.featureRequestURL())
        }

      case let .iCloudSyncToggled(isEnabled):
        state.$settings.withLock { $0.isICloudSyncEnabled = isEnabled }
        return .none

      case .alert:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert)
    .ifLet(\.$speakerEnrollment, action: \.speakerEnrollment) {
      SpeakerEnrollment()
    }
  }

  private func updateInfo(state: inout State) {
    state.appVersion = build.version()
    state.buildNumber = build.buildNumber()
    state.freeSpace = storage.freeSpace().readableString
    state.takenSpace = storage.takenSpace().readableString
    state.takenSpacePercentage = min(1, max(0, 1 - Double(storage.freeSpace()) / Double(storage.freeSpace() + storage.takenSpace())))
  }
}

extension AlertState where Action == SettingsScreen.Action.Alert {
  static var deleteStorage: AlertState {
    AlertState {
      TextState("Confirmation")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
      ButtonState(role: .destructive, action: .deleteStorageDialogConfirmed) {
        TextState("Delete")
      }
    } message: {
      TextState("Are you sure you want to delete all recordings?")
    }
  }

  static var deleteAllModels: AlertState {
    AlertState {
      TextState("Confirmation")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("Cancel")
      }
      ButtonState(role: .destructive, action: .deleteAllModelsDialogConfirmed) {
        TextState("Delete")
      }
    } message: {
      TextState("Are you sure you want to delete all downloaded models?")
    }
  }
}

public extension SharedReaderKey where Self == FileStorageKey<Settings>.Default {
  static var settings: Self {
    Self[FileStorageKey<Settings>.settings, default: .init(selectedModelName: Model.defaultModelName)]
  }
}
