import AudioProcessing
import Common
import ComposableArchitecture
import Inject
import PulseUI
import SwiftUI

// MARK: - SettingsScreenView

struct SettingsScreenView: View {
  @Bindable var store: StoreOf<SettingsScreen>

  var body: some View {
    List {
      ModelSectionView(store: store)
      PremiumFeaturesSectionView(store: store.scope(state: \.premiumFeaturesSection, action: \.premiumFeaturesSection))
      SpeechSectionView(store: store)
      KnownSpeakersSectionView(store: store)

      #if DEBUG
        DebugSectionView(store: store)
      #endif

      StorageSectionView(store: store)
      FeedbackSectionView(store: store)
      FooterSectionView(store: store)
    }
    .background(Color.DS.Background.primary)
    .scrollContentBackground(.hidden)
    .navigationBarTitle("Settings")
    .alert($store.scope(state: \.alert, action: \.alert))
    .sheet(item: $store.scope(state: \.speakerEnrollment, action: \.speakerEnrollment)) { store in
      SpeakerEnrollmentView(store: store)
    }
    .onAppear { store.send(.updateInfo) }
  }
}

// MARK: - KnownSpeakersSectionView

struct KnownSpeakersSectionView: View {
  @Bindable var store: StoreOf<SettingsScreen>

  @State private var profileToForget: SpeakerProfile?
  @State private var profileToRename: SpeakerProfile?
  @State private var speakerNameDraft = ""

  var body: some View {
    Section {
      if store.speakerProfiles.isEmpty {
        Text("No known speakers yet. Add a voice sample or name a speaker in a transcript.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(sortedProfiles) { profile in
          HStack(spacing: .grid(2)) {
            Image(systemName: "person.wave.2.fill")
              .foregroundStyle(Color.accentColor)

            Text(profile.name)
              .foregroundStyle(Color.DS.Text.base)

            Spacer()

            Menu {
              Button("Add Voice Sample", systemImage: "mic.badge.plus") {
                store.send(.addSpeakerSampleTapped(profile.id))
              }
              Button("Rename", systemImage: "pencil") {
                speakerNameDraft = profile.name
                profileToRename = profile
              }
              Divider()
              Button("Forget Speaker", systemImage: "person.crop.circle.badge.minus", role: .destructive) {
                profileToForget = profile
              }
            } label: {
              Image(systemName: "ellipsis.circle")
                .font(.title3)
            }
            .accessibilityLabel("Manage \(profile.name)")
          }
        }
      }
    } header: {
      HStack {
        Text("Known Speakers")
        Spacer()
        Button {
          store.send(.addSpeakerTapped)
        } label: {
          Image(systemName: "plus.circle.fill")
        }
        .accessibilityLabel("Add Speaker")
      }
    } footer: {
      Text("Voice profiles stay on this device and are used only to recognize speakers in future recordings.")
    }
    .listRowBackground(Color.DS.Background.secondary)
    .listRowSeparator(.hidden)
    .alert("Rename Speaker", isPresented: renameAlertIsPresented) {
      TextField("Name", text: $speakerNameDraft)
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        guard let profileToRename else { return }
        store.send(.renameSpeakerSubmitted(profileToRename.id, speakerNameDraft))
        self.profileToRename = nil
      }
    } message: {
      Text("This changes the name in every linked recording.")
    }
    .confirmationDialog(
      "Forget \(profileToForget?.name ?? "this speaker")?",
      isPresented: forgetDialogIsPresented,
      titleVisibility: .visible
    ) {
      Button("Forget Speaker", role: .destructive) {
        guard let profileToForget else { return }
        store.send(.forgetSpeakerTapped(profileToForget.id))
        self.profileToForget = nil
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Future recordings will no longer recognize this voice. Existing transcript labels are preserved.")
    }
  }

  private var sortedProfiles: [SpeakerProfile] {
    store.speakerProfiles.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private var renameAlertIsPresented: Binding<Bool> {
    Binding(
      get: { profileToRename != nil },
      set: {
        if !$0 {
          profileToRename = nil
          speakerNameDraft = ""
        }
      }
    )
  }

  private var forgetDialogIsPresented: Binding<Bool> {
    Binding(
      get: { profileToForget != nil },
      set: {
        if !$0 {
          profileToForget = nil
        }
      }
    )
  }
}

// MARK: - ModelSectionView

struct ModelSectionView: View {
  @Bindable var store: StoreOf<SettingsScreen>

  var body: some View {
    Section {
      SettingsToggleButton(
        icon: .system(name: "text.viewfinder", background: .systemPurple),
        title: "Live Transcription",
        isOn: Binding(store.$settings).isLiveTranscriptionEnabled
      )
      .disabled(!canUseLiveTranscription)

      SettingsSheetButton(
        icon: .system(name: "square.and.arrow.down", background: .systemBlue.lighten(by: 0.1)),
        title: "Model",
        trailingText: store.modelSelector.selectedModelLabel
      ) {
        ModelSelectorView(store: store.scope(state: \.modelSelector, action: \.modelSelector))
      }
    } header: {
      Text("Transcription")
    } footer: {
      Text("Qwen3 ASR 0.6B").bold() + Text(
        " runs fully offline and automatically recognizes Chinese, English, and code-switching between them. Live text refreshes every few seconds to preserve enough context for better accuracy."
      )
    }
    .listRowBackground(Color.DS.Background.secondary).listRowSeparator(.hidden)
  }

  private var canUseLiveTranscription: Bool {
    #if APPSTORE
      store.premiumFeaturesSection.premiumFeatures.liveTranscriptionIsPurchased == true
    #else
      true
    #endif
  }
}

// MARK: - SpeechSectionView

struct SpeechSectionView: View {
  @Bindable var store: StoreOf<SettingsScreen>

  var body: some View {
    Section("Speech") {
      SettingsInlinePickerButton(
        icon: .system(name: "globe", background: .systemGreen.darken(by: 0.1)),
        title: "Language",
        choices: store.availableLanguages.map(\.titleCased),
        selectedIndex: $store.selectedLanguageIndex
      )
    }
    .listRowBackground(Color.DS.Background.secondary).listRowSeparator(.hidden)

    Section {
      SettingsToggleButton(
        icon: .system(name: "waveform.path.ecg", background: .systemPurple),
        title: "Allow Background Audio",
        isOn: Binding(store.$settings).shouldMixWithOtherAudio
      )
    } footer: {
      Text(
        "Turn this on to allow background audio from other apps to continue playing while you record. This app will lower the volume of other audio sources (ducking) during recording. Turn off to ensure other apps are paused and only your recording is captured."
      )
    }
    .listRowBackground(Color.DS.Background.secondary).listRowSeparator(.hidden)
  }
}

// MARK: - DebugSectionView

#if DEBUG
  struct DebugSectionView: View {
    @Bindable var store: StoreOf<SettingsScreen>

    @State private var logs: [(Int, String)] = []

    var body: some View {
      Section {
        SettingsToggleButton(
          icon: .system(name: "wand.and.stars", background: .systemTeal),
          title: "Enable Fixtures",
          isOn: Binding(store.$settings).useMockedClients
        )

        SettingsSheetButton(icon: .system(name: "ladybug", background: .systemGreen), title: "Show logs") {
          NavigationStack {
            ConsoleView(store: .shared)
          }
        }

        SettingsSheetButton(icon: .system(name: "chart", background: .systemBlue), title: "Show system stats") {
          StatisticsView()
        }
      } header: {
        Text("Debug")
      }
      .listRowBackground(Color.DS.Background.secondary).listRowSeparator(.hidden)
    }
  }
#endif

// MARK: - StorageSectionView

struct StorageSectionView: View {
  @Bindable var store: StoreOf<SettingsScreen>

  var body: some View {
    Section {
      Group {
        VStack(alignment: .leading, spacing: .grid(1)) {
          HStack(spacing: 0) {
            Text("Taken: \(store.takenSpace)").textStyle(.body)

            Spacer()

            Text("Available: \(store.freeSpace)").textStyle(.body)
          }

          GeometryReader { geometry in
            Group {
              HStack(spacing: 0) {
                LinearGradient.easedGradient(colors: [.systemPurple, .systemOrange], startPoint: .bottomLeading, endPoint: .topTrailing)
                  .frame(width: geometry.size.width * store.takenSpacePercentage)

                Color.DS.Background.tertiary
              }
            }
          }
          .frame(height: .grid(4)).continuousCornerRadius(.grid(1))
        }
      }

      SettingsToggleButton(
        icon: .system(name: "icloud.and.arrow.up", background: .systemBlue),
        title: "iCloud Backup",
        isOn: Binding(
          get: { store.settings.isICloudSyncEnabled },
          set: { store.send(.iCloudSyncToggled($0)) }
        )
      )
      .disabled(store.isICloudSyncInProgress)
      .blur(radius: store.isICloudSyncInProgress ? 3 : 0)
      .overlay(store.isICloudSyncInProgress ? ProgressView().progressViewStyle(.circular) : nil)
      .animation(.easeInOut, value: store.isICloudSyncInProgress)

      SettingsButton(icon: .system(name: "trash", background: .systemYellow.darken(by: 0.1)), title: "Delete All Recordings") {
        store.send(.deleteStorageTapped)
      }
      SettingsButton(icon: .system(name: "trash", background: .systemPurple.darken(by: 0.1)), title: "Delete All Models") {
        store.send(.deleteAllModelsTapped)
      }
    } header: {
      Text("Storage")
    }
    .listRowBackground(Color.DS.Background.secondary).listRowSeparator(.hidden)
  }
}

// MARK: - FeedbackSectionView

struct FeedbackSectionView: View {
  @Bindable var store: StoreOf<SettingsScreen>

  var body: some View {
    Section {
      SettingsButton(icon: .system(name: "star.fill", background: .systemYellow.darken(by: 0.05)), title: "Rate the App") {
        store.send(.rateAppTapped)
      }

      SettingsButton(icon: .system(name: "exclamationmark.triangle", background: .systemRed), title: "Report a Bug") {
        store.send(.reportBugTapped)
      }

      SettingsButton(icon: .system(name: "sparkles", background: .systemPurple.darken(by: 0.1)), title: "Suggest New Feature") {
        store.send(.suggestFeatureTapped)
      }
    }
    .listRowBackground(Color.DS.Background.secondary).listRowSeparator(.hidden)
  }
}

// MARK: - FooterSectionView

struct FooterSectionView: View {
  @Bindable var store: StoreOf<SettingsScreen>

  var body: some View {
    Section {
      VStack(spacing: .grid(1)) {
        Text("v\(store.appVersion) (\(store.buildNumber))").textStyle(.caption)
        Text("Made with ♥ in Amsterdam").foregroundColor(.DS.Text.accentAlt).textStyle(.caption)
          .mask { LinearGradient.easedGradient(colors: [.systemPurple, .systemRed], startPoint: .bottomLeading, endPoint: .topTrailing) }
        Button {
          store.send(.openPersonalWebsite)
        } label: {
          Text("by Igor Tarasenko").foregroundColor(.DS.Text.accentAlt).textStyle(.caption)
        }
      }
      .frame(maxWidth: .infinity)

      HStack(spacing: .grid(1)) { Button("Saik0s/Whisperboard") { store.send(.openGitHub) } }.buttonStyle(SmallButtonStyle())
        .frame(maxWidth: .infinity)
    }
    .listRowBackground(Color.clear).listRowSeparator(.hidden)
  }
}

// MARK: - SmallButtonStyle

struct SmallButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .textStyle(.secondaryButton)
      .padding(.horizontal, .grid(2))
      .padding(.vertical, .grid(1))
      .background(RoundedRectangle(cornerRadius: .grid(1)).fill(Color.DS.Background.accentAlt.opacity(0.2)))
      .scaleEffect(configuration.isPressed ? 0.95 : 1)
  }
}
