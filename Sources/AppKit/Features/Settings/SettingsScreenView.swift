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
