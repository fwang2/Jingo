import AudioProcessing
import ComposableArchitecture
import SwiftUI

// MARK: - KnownSpeakersSectionView

struct KnownSpeakersSectionView: View {
  @Bindable var store: StoreOf<SettingsScreen>

  @State private var isSelectingProfiles = false
  @State private var selectedProfileIDs: Set<UUID> = []
  @State private var profilesToForget: [SpeakerProfile] = []
  @State private var profileToRename: SpeakerProfile?
  @State private var speakerNameDraft = ""
  @State private var profileIDsToMerge: Set<UUID> = []
  @State private var mergeTargetProfileID: UUID?
  @State private var mergedNameDraft = ""

  var body: some View {
    Section {
      if store.speakerProfiles.isEmpty {
        Text("No known speakers yet. Add a voice sample or name a speaker in a transcript.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(sortedProfiles) { profile in
          profileRow(profile)
        }

        if isSelectingProfiles {
          HStack {
            Button {
              beginMergingSelectedProfiles()
            } label: {
              Label("Merge", systemImage: "person.2")
            }
            .disabled(selectedProfileIDs.count < 2)

            Spacer()

            Button(role: .destructive) {
              profilesToForget = selectedProfiles
            } label: {
              Label("Remove", systemImage: "trash")
            }
            .disabled(selectedProfileIDs.isEmpty)
          }
          .buttonStyle(.borderless)
        }
      }
    } header: {
      HStack {
        Text("Known Speakers")
        Spacer()
        if !store.speakerProfiles.isEmpty {
          Button(isSelectingProfiles ? "Done" : "Select") {
            if isSelectingProfiles {
              clearSelection()
            } else {
              isSelectingProfiles = true
            }
          }
          .buttonStyle(.borderless)
        }
        if !isSelectingProfiles {
          Button {
            store.send(.addSpeakerTapped)
          } label: {
            Image(systemName: "plus.circle.fill")
          }
          .accessibilityLabel("Add Speaker")
        }
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
        guard let profileToRename else {
          return
        }
        store.send(.renameSpeakerSubmitted(profileToRename.id, speakerNameDraft))
        self.profileToRename = nil
      }
    } message: {
      Text("This changes the name in every linked recording.")
    }
    .alert("Merge Speakers", isPresented: mergeAlertIsPresented) {
      TextField("Name", text: $mergedNameDraft)
      Button("Cancel", role: .cancel) {}
      Button("Merge") {
        guard let mergeTargetProfileID else {
          return
        }
        store.send(
          .mergeSpeakerProfilesSubmitted(
            profileIDsToMerge,
            into: mergeTargetProfileID,
            name: mergedNameDraft
          )
        )
        clearSelection()
      }
    } message: {
      Text("Voice samples and linked recordings will be combined under this name.")
    }
    .confirmationDialog(
      forgetDialogTitle,
      isPresented: forgetDialogIsPresented,
      titleVisibility: .visible
    ) {
      Button(profilesToForget.count == 1 ? "Remove Profile" : "Remove Profiles", role: .destructive) {
        store.send(.forgetSpeakersTapped(Set(profilesToForget.map(\.id))))
        profilesToForget = []
        clearSelection()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Future recordings will no longer recognize this voice. Existing transcript labels are preserved.")
    }
  }

  @ViewBuilder
  private func profileRow(_ profile: SpeakerProfile) -> some View {
    if isSelectingProfiles {
      Button {
        if selectedProfileIDs.contains(profile.id) {
          selectedProfileIDs.remove(profile.id)
        } else {
          selectedProfileIDs.insert(profile.id)
        }
      } label: {
        HStack(spacing: .grid(2)) {
          Image(systemName: selectedProfileIDs.contains(profile.id) ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(
              selectedProfileIDs.contains(profile.id)
                ? Color.accentColor
                : Color.DS.Text.base.opacity(0.5)
            )
          profileLabel(profile)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(profile.name), \(selectedProfileIDs.contains(profile.id) ? "selected" : "not selected")")
    } else {
      HStack(spacing: .grid(2)) {
        profileLabel(profile)

        Menu {
          Button("Add Voice Sample", systemImage: "mic.badge.plus") {
            store.send(.addSpeakerSampleTapped(profile.id))
          }
          Button("Rename", systemImage: "pencil") {
            speakerNameDraft = profile.name
            profileToRename = profile
          }
          Divider()
          Button("Remove Profile", systemImage: "person.crop.circle.badge.minus", role: .destructive) {
            profilesToForget = [profile]
          }
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.title3)
        }
        .accessibilityLabel("Manage \(profile.name)")
      }
    }
  }

  private func profileLabel(_ profile: SpeakerProfile) -> some View {
    HStack(spacing: .grid(2)) {
      Image(systemName: "person.wave.2.fill")
        .foregroundStyle(Color.accentColor)

      Text(profile.name)
        .foregroundStyle(Color.DS.Text.base)

      Spacer()
    }
  }

  private var sortedProfiles: [SpeakerProfile] {
    store.speakerProfiles.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private var selectedProfiles: [SpeakerProfile] {
    sortedProfiles.filter { selectedProfileIDs.contains($0.id) }
  }

  private var forgetDialogTitle: String {
    if profilesToForget.count == 1 {
      return "Remove \(profilesToForget[0].name)?"
    }
    return "Remove \(profilesToForget.count) profiles?"
  }

  private func beginMergingSelectedProfiles() {
    guard let targetProfile = selectedProfiles.first, selectedProfiles.count >= 2 else {
      return
    }
    profileIDsToMerge = selectedProfileIDs
    mergeTargetProfileID = targetProfile.id
    mergedNameDraft = targetProfile.name
  }

  private func clearSelection() {
    isSelectingProfiles = false
    selectedProfileIDs = []
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
      get: { !profilesToForget.isEmpty },
      set: {
        if !$0 {
          profilesToForget = []
        }
      }
    )
  }

  private var mergeAlertIsPresented: Binding<Bool> {
    Binding(
      get: { mergeTargetProfileID != nil },
      set: {
        if !$0 {
          profileIDsToMerge = []
          mergeTargetProfileID = nil
          mergedNameDraft = ""
        }
      }
    )
  }
}
