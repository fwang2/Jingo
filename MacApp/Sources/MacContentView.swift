import Foundation
import MeetingSummaryCore
import SwiftUI

// MARK: - MacContentView

struct MacContentView: View {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var controller = MacTranscriptionController()
  @State private var expandedRecordingIDs: Set<UUID> = []
  @State private var profileToForget: SpeakerProfile?
  @State private var profileToRename: SpeakerProfile?
  @State private var speakerEnrollmentRequest: SpeakerEnrollmentRequest?
  @State private var speakerEnrollmentName = ""
  @State private var speakerRenameRequest: SpeakerRenameRequest?
  @State private var speakerNameDraft = ""
  @State private var speakerProfileNameDraft = ""
  @State private var transcriptIsNearBottom = true
  @State private var summaryInstructionsTab: SummaryInstructionsTab = .edit

  var body: some View {
    HStack(spacing: 0) {
      sidebar

      Divider()

      VStack(spacing: 0) {
        content

        Divider()

        recordingDock
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .task {
      controller.prepareModelIfNeeded()
      controller.startHandsFreeIfNeeded()
      controller.startSyncFolderSettings()
    }
    .onChange(of: scenePhase) { _, newValue in
      guard newValue == .active else {
        return
      }
      controller.refreshSyncFolderIfNeeded()
    }
    .alert("Jingo Error", isPresented: errorIsPresented) {
      Button("OK") { controller.errorMessage = nil }
    } message: {
      Text(controller.errorMessage ?? "Unknown error")
    }
    .alert("Rename Speaker", isPresented: renameSpeakerIsPresented) {
      TextField("Name", text: $speakerNameDraft)
        .accessibilityIdentifier("speaker.renameField")
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        guard let request = speakerRenameRequest else { return }
        controller.renameSpeaker(
          request.speakerID,
          to: speakerNameDraft,
          recordingID: request.recordingID
        )
        speakerRenameRequest = nil
      }
    } message: {
      Text("This name will also help recognize the speaker in future recordings.")
    }
    .alert("Rename Known Speaker", isPresented: renameProfileIsPresented) {
      TextField("Name", text: $speakerProfileNameDraft)
        .accessibilityIdentifier("speakerProfile.renameField")
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        guard let profileToRename else { return }
        controller.renameSpeakerProfile(profileToRename.id, to: speakerProfileNameDraft)
        self.profileToRename = nil
      }
    } message: {
      Text("This changes the name in every linked recording.")
    }
    .confirmationDialog(
      "Forget \(profileToForget?.name ?? "this speaker")?",
      isPresented: forgetProfileIsPresented,
      titleVisibility: .visible
    ) {
      Button("Forget Speaker", role: .destructive) {
        guard let profileToForget else { return }
        controller.forgetSpeakerProfile(profileToForget.id)
        self.profileToForget = nil
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Future recordings will no longer recognize this voice. Existing transcript labels are preserved.")
    }
    .sheet(item: $speakerEnrollmentRequest) { request in
      speakerEnrollmentSheet(request)
        .onDisappear {
          controller.cancelSpeakerSampleRecording()
          speakerEnrollmentName = ""
        }
    }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 11) {
        Image(systemName: "waveform.and.mic")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 34, height: 34)
          .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 9))

        VStack(alignment: .leading, spacing: 1) {
          Text("Jingo")
            .font(.headline)
          Text("Private transcription")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 20)
      .padding(.bottom, 24)

      Text("WORKSPACE")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 19)
        .padding(.bottom, 7)

      VStack(spacing: 4) {
        sidebarButton("Live Transcript", systemImage: "text.quote", section: .home)
        sidebarButton("Recordings", systemImage: "waveform", section: .recordings)
        sidebarButton("Known Speakers", systemImage: "person.wave.2", section: .speakers)
      }
      .padding(.horizontal, 10)

      Spacer()

      VStack(spacing: 4) {
        sidebarButton("Backup & Restore", systemImage: "externaldrive", section: .account)
        sidebarButton("Settings", systemImage: "gearshape", section: .settings)

        HStack(spacing: 7) {
          Image(systemName: "lock.fill")
            .font(.caption2)
          Text("Audio stays on this Mac")
            .font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 12)
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 16)
    }
    .frame(width: 218)
    .background(.ultraThinMaterial)
  }

  @ViewBuilder private var content: some View {
    switch controller.selectedSection {
    case .home:
      home
    case .recordings:
      recordings
    case .speakers:
      knownSpeakers
    case .account:
      account
    case .settings:
      settings
    }
  }

  private var home: some View {
    VStack(spacing: 0) {
      pageHeader(
        title: "Live Transcript",
        subtitle: "English and Chinese, transcribed locally"
      )

      Divider()

      transcriptCanvas
    }
  }

  private var transcriptCanvas: some View {
    GeometryReader { geometry in
      let horizontalPadding: CGFloat = geometry.size.width < 760 ? 24 : 32

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            if controller.transcript.isEmpty {
              emptyTranscript
                .frame(
                  maxWidth: .infinity,
                  minHeight: max(geometry.size.height - 48, 0)
                )
            } else {
              Group {
                if controller.speakerTurns.isEmpty || !speakerCheckpointMatchesTranscript {
                  Text(controller.transcript)
                    .font(.system(
                      size: CGFloat(controller.transcriptFontSize),
                      weight: .regular,
                      design: .rounded
                    ))
                    .lineSpacing(TranscriptCanvas.lineSpacing)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .accessibilityElement()
                    .accessibilityLabel(controller.transcript)
                    .accessibilityIdentifier("transcript.liveText")
                } else {
                  VStack(alignment: .leading, spacing: 24) {
                    speakerTurnsView(
                      controller.speakerTurns,
                      names: controller.speakerNames,
                      recordingID: nil,
                      presentation: .canvas,
                      allowsRenaming: !controller.isRecording
                    )

                    if !liveTranscriptTail.isEmpty {
                      Text(liveTranscriptTail)
                        .font(.system(
                          size: CGFloat(controller.transcriptFontSize),
                          weight: .regular,
                          design: .rounded
                        ))
                        .lineSpacing(TranscriptCanvas.lineSpacing)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .accessibilityElement()
                        .accessibilityLabel(liveTranscriptTail)
                        .accessibilityIdentifier("transcript.liveTail")
                    }
                  }
                }
              }
              .padding(.vertical, 28)
              .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Color.clear
              .frame(height: 1)
              .id(TranscriptCanvas.bottomID)
              .background {
                GeometryReader { bottomGeometry in
                  Color.clear.preference(
                    key: TranscriptBottomOffsetKey.self,
                    value: bottomGeometry.frame(in: .named(TranscriptCanvas.coordinateSpace)).maxY
                  )
                }
              }
          }
          .padding(.horizontal, horizontalPadding)
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("transcript.canvas")
        .coordinateSpace(name: TranscriptCanvas.coordinateSpace)
        .onPreferenceChange(TranscriptBottomOffsetKey.self) { bottomOffset in
          transcriptIsNearBottom = bottomOffset <= geometry.size.height + 72
        }
        .onChange(of: controller.transcript) { _, _ in
          guard transcriptIsNearBottom else { return }
          proxy.scrollTo(TranscriptCanvas.bottomID, anchor: .bottom)
        }
        .onChange(of: controller.speakerTurns.count) { _, _ in
          guard transcriptIsNearBottom else { return }
          proxy.scrollTo(TranscriptCanvas.bottomID, anchor: .bottom)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .textBackgroundColor))
  }

  private var speakerCheckpointMatchesTranscript: Bool {
    !controller.isRecording
      || (!controller.speakerAttributedText.isEmpty
        && controller.transcript.hasPrefix(controller.speakerAttributedText))
  }

  private var liveTranscriptTail: String {
    guard controller.isRecording,
          controller.transcript.hasPrefix(controller.speakerAttributedText)
    else {
      return ""
    }
    return String(controller.transcript.dropFirst(controller.speakerAttributedText.count))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var emptyTranscript: some View {
    VStack(spacing: 15) {
      Image(systemName: controller.isRecording ? "waveform" : "mic")
        .font(.system(size: 27, weight: .medium))
        .foregroundStyle(controller.isRecording ? Color.red : Color.accentColor)
        .frame(width: 58, height: 58)
        .background(
          (controller.isRecording ? Color.red : Color.accentColor).opacity(0.1),
          in: Circle()
        )

      VStack(spacing: 6) {
        Text(controller.isRecording ? "Listening…" : "Ready when you are")
          .font(.title3.weight(.semibold))
        Text(
          controller.isRecording
            ? "Your words will appear here as they’re transcribed."
            : "Press Record to begin a private, on-device transcript."
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      }
    }
    .padding(40)
    .accessibilityIdentifier("transcript.empty")
  }

  private var recordings: some View {
    VStack(spacing: 0) {
      pageHeader(
        title: "Recordings",
        subtitle: recordingCountText
      )

      Divider()

      if controller.recordings.isEmpty {
        ContentUnavailableView(
          "No recordings yet",
          systemImage: "waveform",
          description: Text("Start a recording to build your private library.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(spacing: 10) {
            ForEach(controller.recordings) { recording in
              recordingRow(recording)
            }
          }
          .padding(24)
          .frame(maxWidth: 940)
          .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
      }
    }
  }

  private func recordingRow(_ recording: MacRecording) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        Button {
          controller.play(recording)
        } label: {
          Image(systemName: "play.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 34, height: 34)
            .background(Color.accentColor.opacity(0.11), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play recording")

        VStack(alignment: .leading, spacing: 5) {
          Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened))
            .font(.headline)

          Text(recording.transcript.isEmpty ? "Audio recording" : recording.transcript)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        Text(duration(recording.duration))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(.quaternary, in: Capsule())

        if !recording.transcript.isEmpty {
          Button {
            if expandedRecordingIDs.contains(recording.id) {
              expandedRecordingIDs.remove(recording.id)
            } else {
              expandedRecordingIDs.insert(recording.id)
            }
          } label: {
            Image(systemName: expandedRecordingIDs.contains(recording.id) ? "chevron.up" : "chevron.down")
              .frame(width: 24, height: 24)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(expandedRecordingIDs.contains(recording.id) ? "Hide transcript" : "Show transcript")
        }
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 15)

      if expandedRecordingIDs.contains(recording.id) {
        Divider()
          .padding(.horizontal, 18)

        VStack(alignment: .leading, spacing: 22) {
          recordingSummary(recording)

          if let turns = recording.speakerTurns, !turns.isEmpty {
            Divider()
            speakerTurnsView(
              turns,
              names: recording.speakerNames ?? [:],
              recordingID: recording.id
            )
          }
        }
        .padding(18)
      }
    }
    .background(
      Color(nsColor: .textBackgroundColor),
      in: RoundedRectangle(cornerRadius: 12)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12)
        .strokeBorder(.separator.opacity(0.45))
    }
  }

  @ViewBuilder
  private func recordingSummary(_ recording: MacRecording) -> some View {
    if let summary = recording.summary {
      switch summary.status {
      case .generating, .queued:
        HStack(spacing: 12) {
          ProgressView()
            .controlSize(.small)
          VStack(alignment: .leading, spacing: 2) {
            Text("Creating summary")
              .font(.headline)
            Text("Jingo is analyzing this transcript on your Mac.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Cancel") {
            controller.cancelSummary(for: recording.id)
          }
        }

      case let .failed(message):
        VStack(alignment: .leading, spacing: 8) {
          Label("Summary unavailable", systemImage: "exclamationmark.triangle")
            .font(.headline)
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)

          HStack {
            Button("Try Again") {
              controller.generateSummary(for: recording.id)
            }

            if !controller.isSummaryModelReady,
               !controller.isPreparingSummaryModel {
              Button("Download Model", systemImage: "arrow.down.circle") {
                controller.prepareSummaryModel()
              }
              .accessibilityIdentifier("recording.prepareSummaryModel")
            }
          }

          if controller.isPreparingSummaryModel {
            summaryModelProgress
          }
        }

      case .completed:
        completedSummary(summary, recording: recording)
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        Text("Meeting Summary")
          .font(.headline)
        Text("Create key points, decisions, action items, and highlights locally.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("Create Summary", systemImage: "sparkles") {
          controller.generateSummary(for: recording.id)
        }
      }
    }
  }

  private func completedSummary(
    _ summary: MeetingSummary,
    recording: MacRecording
  ) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("Meeting Summary", systemImage: "sparkles")
          .font(.headline)
        Spacer()
        Button("Regenerate") {
          controller.generateSummary(for: recording.id)
        }
        .buttonStyle(.borderless)
      }

      if !summary.overview.isEmpty {
        MarkdownText(summary.overview)
          .font(.body)
          .textSelection(.enabled)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("summary.overview")
      }

      summaryList(
        "Key Findings",
        items: summary.keyPoints,
        identifierPrefix: "summary.keyPoint"
      )
      summaryList(
        "Decisions",
        items: summary.decisions,
        identifierPrefix: "summary.decision"
      )
      summaryList(
        "Not Decided / Still Open",
        items: summary.openItems,
        identifierPrefix: "summary.openItem"
      )
      summaryList(
        "Important Contributions by Participant",
        items: summary.participantContributions,
        identifierPrefix: "summary.participantContribution"
      )

      if !summary.actionItems.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("Action Items")
            .font(.subheadline.bold())
          ForEach(Array(summary.actionItems.enumerated()), id: \.element.id) { index, item in
            VStack(alignment: .leading, spacing: 3) {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.circle")
                MarkdownText(item.task, style: .inline)
              }
              .accessibilityElement(children: .combine)
              .accessibilityIdentifier("summary.actionItem.\(index)")

              let details = [item.owner, item.dueDate].compactMap { $0 }
              if !details.isEmpty {
                MarkdownText(details.joined(separator: " · "), style: .inline)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }

      summaryList(
        "Risks or Follow-up Questions",
        items: summary.risksAndFollowUpQuestions,
        identifierPrefix: "summary.riskOrQuestion"
      )

      if !summary.highlights.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("Highlights")
            .font(.subheadline.bold())
          ForEach(Array(summary.highlights.enumerated()), id: \.element.id) { index, highlight in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              MarkdownText(highlight.text, style: .inline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("summary.highlight.\(index)")
              if let startTimeMS = highlightStartTime(highlight, recording: recording) {
                Button(timestamp(startTimeMS)) {
                  controller.play(recording, at: startTimeMS)
                }
                .buttonStyle(.borderless)
                .font(.caption.monospacedDigit())
              }
            }
          }
        }
      }

      if !summary.meetingStatus.isEmpty {
        Divider()
        MarkdownText(summary.meetingStatus, style: .inline)
          .font(.body.italic())
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("summary.meetingStatus")
      }
    }
    .textSelection(.enabled)
  }

  @ViewBuilder
  private func summaryList(
    _ title: String,
    items: [String],
    identifierPrefix: String
  ) -> some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 7) {
        Text(title)
          .font(.subheadline.bold())
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            MarkdownText(item, style: .inline)
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("\(identifierPrefix).\(index)")
        }
      }
    }
  }

  private func highlightStartTime(
    _ highlight: MeetingSummary.Highlight,
    recording: MacRecording
  ) -> Int64? {
    guard let sourceID = highlight.sourceTurnIDs.first,
          sourceID.first == "T",
          let oneBasedIndex = Int(sourceID.dropFirst()),
          let turns = recording.speakerTurns,
          turns.indices.contains(oneBasedIndex - 1)
    else {
      return nil
    }
    return turns[oneBasedIndex - 1].startTimeMS
  }

  private func speakerTurnsView(
    _ turns: [MacSpeakerTurn],
    names: [String: String],
    recordingID: UUID?,
    presentation: SpeakerTurnPresentation = .recording,
    allowsRenaming: Bool = true
  ) -> some View {
    let speakerIDs = orderedSpeakerIDs(in: turns)
    let isCanvas = presentation == .canvas
    let shouldTintTurns = !isCanvas || speakerIDs.count > 1

    return LazyVStack(alignment: .leading, spacing: isCanvas ? 24 : 20) {
      ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
        let colorIndex = turn.speakerID.flatMap(speakerIDs.firstIndex)
        let color = speakerColor(at: colorIndex)
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            if let speakerID = turn.speakerID {
              let speakerName = names[speakerID]
                ?? "Speaker \((speakerIDs.firstIndex(of: speakerID) ?? 0) + 1)"
              if allowsRenaming {
                Button {
                  beginRenaming(
                    speakerID: speakerID,
                    currentName: speakerName,
                    recordingID: recordingID
                  )
                } label: {
                  Label(speakerName, systemImage: "person.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(color.opacity(0.13), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Rename speaker")
                .accessibilityIdentifier("speaker.\(speakerID)")
              } else {
                Label(speakerName, systemImage: "person.fill")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(color)
                  .padding(.horizontal, 9)
                  .padding(.vertical, 5)
                  .background(color.opacity(0.13), in: Capsule())
                  .accessibilityElement()
                  .accessibilityLabel(speakerName)
                  .accessibilityIdentifier("speaker.\(speakerID)")
              }
            }

            Text("\(timestamp(turn.startTimeMS)) – \(timestamp(turn.endTimeMS))")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .accessibilityElement()
              .accessibilityLabel("\(timestamp(turn.startTimeMS)) – \(timestamp(turn.endTimeMS))")
              .accessibilityIdentifier("speakerTurn.timestamp.\(index)")
          }

          Text(turn.text)
            .font(isCanvas
              ? .system(size: CGFloat(controller.transcriptFontSize), weight: .regular, design: .rounded)
              : .body)
              .lineSpacing(isCanvas ? TranscriptCanvas.lineSpacing : 4)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityElement()
              .accessibilityLabel(turn.text)
              .accessibilityIdentifier("speakerTurn.text.\(index)")
        }
        .padding(shouldTintTurns ? 14 : 0)
        .background {
          if shouldTintTurns, turn.speakerID != nil {
            RoundedRectangle(cornerRadius: 10)
              .fill(color.opacity(isCanvas ? 0.045 : 0.055))
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("speakerTurn.\(index)")
      }
    }
  }

  private func orderedSpeakerIDs(in turns: [MacSpeakerTurn]) -> [String] {
    turns.reduce(into: []) { result, turn in
      if let speakerID = turn.speakerID, !result.contains(speakerID) {
        result.append(speakerID)
      }
    }
  }

  private func speakerColor(at index: Int?) -> Color {
    let colors: [Color] = [.purple, .green, .orange, .pink, .blue, .cyan]
    guard let index else { return .secondary }
    return colors[index % colors.count]
  }

  private func beginRenaming(
    speakerID: String,
    currentName: String,
    recordingID: UUID?
  ) {
    speakerNameDraft = currentName
    speakerRenameRequest = SpeakerRenameRequest(
      speakerID: speakerID,
      recordingID: recordingID
    )
  }

  private var renameSpeakerIsPresented: Binding<Bool> {
    Binding(
      get: { speakerRenameRequest != nil },
      set: {
        if !$0 {
          speakerRenameRequest = nil
          speakerNameDraft = ""
        }
      }
    )
  }

  private func timestamp(_ milliseconds: Int64) -> String {
    let totalSeconds = max(0, milliseconds / 1000)
    let hours = totalSeconds / 3600
    let minutes = totalSeconds % 3600 / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
      return String(format: "%02lld:%02lld:%02lld", hours, minutes, seconds)
    }
    return String(format: "%02lld:%02lld", minutes, seconds)
  }

  private var settings: some View {
    VStack(spacing: 0) {
      pageHeader(
        title: "Settings",
        subtitle: "Transcription and model preferences"
      )

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          settingsSection("TRANSCRIPTION") {
            VStack(spacing: 0) {
              HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                  Text("Audio source")
                    .font(.body.weight(.medium))
                  Text(audioSourceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Audio source", selection: $controller.audioSourceMode) {
                  ForEach(MacAudioSourceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                  }
                }
                .labelsHidden()
                .frame(width: 220)
                .disabled(controller.isRecording)
                .accessibilityIdentifier("settings.audioSource")
              }
              .padding(16)

              Divider()
                .padding(.leading, 16)

              HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                  Text("Hands-free listening")
                    .font(.body.weight(.medium))
                  Text("Start listening automatically while Jingo is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $controller.isHandsFreeModeEnabled)
                  .labelsHidden()
                  .toggleStyle(.switch)
                  .disabled(controller.isRecording || controller.isLoadingModel)
                  .accessibilityIdentifier("settings.handsFreeListening")
              }
              .padding(16)

              Divider()
                .padding(.leading, 16)

              HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                  Text("Live transcription")
                    .font(.body.weight(.medium))
                  Text("Show English and Chinese text while recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $controller.isLiveTranscriptionEnabled)
                  .labelsHidden()
                  .toggleStyle(.switch)
              }
              .padding(16)

              Divider()
                .padding(.leading, 16)

              HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                  Text("Transcript text size")
                    .font(.body.weight(.medium))
                  Text("Adjust the text shown in the transcript canvas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Stepper(
                  value: $controller.transcriptFontSize,
                  in: MacTranscriptionController.transcriptFontSizeRange,
                  step: 1
                ) {
                  Text("\(Int(controller.transcriptFontSize)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                }
                .accessibilityLabel("Transcript text size")
                .accessibilityValue("\(Int(controller.transcriptFontSize)) points")
                .accessibilityIdentifier("settings.transcriptFontSize")
              }
              .padding(16)
            }
          }

          settingsSection("MODEL") {
            VStack(spacing: 0) {
              HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                  Text("Default model")
                    .font(.body.weight(.medium))
                  Text(controller.transcriptionModel.behaviorDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Default model", selection: $controller.transcriptionModel) {
                  ForEach(MacTranscriptionModel.allCases) { model in
                    Text(model.title).tag(model)
                  }
                }
                .labelsHidden()
                .frame(width: 250)
                .disabled(controller.isRecording || controller.isLoadingModel)
                .accessibilityIdentifier("settings.transcriptionModel")
              }
              .padding(16)

              Divider()
                .padding(.leading, 16)

              settingsRow("Status", value: controller.statusText)

              if controller.isLoadingModel {
                ProgressView(value: controller.downloadProgress)
                  .padding(.horizontal, 16)
                  .padding(.bottom, 16)
              } else if !controller.isModelReady {
                Divider()
                  .padding(.leading, 16)

                Button("Prepare Model", systemImage: "arrow.down.circle") {
                  controller.prepareModel()
                }
                .padding(16)
              }
            }
          }

          meetingSummarySettings

          Label("The model and your recordings stay on this Mac.", systemImage: "lock.shield.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(28)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
      }
      .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
  }

  private var meetingSummarySettings: some View {
    settingsSection("MEETING SUMMARIES") {
      VStack(spacing: 0) {
        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Automatic summaries")
              .font(.body.weight(.medium))
            Text("Create a summary after each completed transcription.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer()

          Toggle("", isOn: $controller.automaticSummariesEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityIdentifier("settings.automaticSummaries")
        }
        .padding(16)

        Divider()
          .padding(.leading, 16)

        HStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Summary model")
              .font(.body.weight(.medium))

            HStack(spacing: 0) {
              Text("On-device")
              Text(" · ")
              Text("Qwen3 4B · 4-bit")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }

          Spacer()

          if controller.isPreparingSummaryModel {
            summaryModelProgress
              .frame(width: 190)
          } else if controller.isSummaryModelReady {
            Text(controller.summaryModelStatusText)
              .foregroundStyle(.secondary)
          } else {
            HStack(spacing: 12) {
              Text(controller.summaryModelStatusText)
                .foregroundStyle(.secondary)

              Button("Download Model", systemImage: "arrow.down.circle") {
                controller.prepareSummaryModel()
              }
              .accessibilityIdentifier("settings.prepareSummaryModel")
            }
          }
        }
        .padding(16)

        Divider()
          .padding(.leading, 16)

        summaryInstructionsSettings
          .padding(16)
      }
    }
  }

  private var summaryInstructionsSettings: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Summary instructions")
            .font(.body.weight(.medium))
          Text("Guide tone, focus, terminology, and formatting.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        if controller.customSummaryInstructions != MacMeetingSummarizer.defaultCustomInstructions {
          Button("Restore Default") {
            controller.customSummaryInstructions = MacMeetingSummarizer.defaultCustomInstructions
          }
          .buttonStyle(.borderless)
        }

        if !controller.customSummaryInstructions.isEmpty {
          Button("Clear") {
            controller.customSummaryInstructions = ""
          }
          .buttonStyle(.borderless)
        }
      }

      HStack {
        HStack(spacing: 0) {
          summaryInstructionsTabButton("Edit", tab: .edit)
          summaryInstructionsTabButton("Preview", tab: .preview)
        }
        .padding(3)
        .background(
          Color(nsColor: .controlBackgroundColor),
          in: RoundedRectangle(cornerRadius: 8)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.summaryInstructionsTabs")

        Spacer()

        Text("Saved automatically")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      switch summaryInstructionsTab {
      case .edit:
        TextEditor(text: $controller.customSummaryInstructions)
          .font(.body)
          .frame(height: 240)
          .padding(7)
          .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 10)
              .strokeBorder(.separator.opacity(0.55))
          }
          .accessibilityLabel("Custom summary instructions")
          .accessibilityIdentifier("settings.summaryInstructions")

      case .preview:
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            if controller.customSummaryInstructions
              .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              Text("Your formatted instructions will appear here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            } else {
              MarkdownText(controller.customSummaryInstructions)
                .textSelection(.enabled)
            }
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 240)
        .background(
          Color(nsColor: .textBackgroundColor),
          in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 10)
            .strokeBorder(.separator.opacity(0.55))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.summaryInstructionsPreview")
      }

      Label(
        "Factual grounding, the structured result, and meeting-length limits are always enforced.",
        systemImage: "shield.checkered"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func summaryInstructionsTabButton(
    _ title: String,
    tab: SummaryInstructionsTab
  ) -> some View {
    Button(title) {
      summaryInstructionsTab = tab
    }
    .buttonStyle(.plain)
    .font(.caption.weight(.semibold))
    .foregroundStyle(summaryInstructionsTab == tab ? .primary : .secondary)
    .frame(minWidth: 72)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(
      summaryInstructionsTab == tab
        ? Color(nsColor: .selectedControlColor).opacity(0.18)
        : .clear,
      in: RoundedRectangle(cornerRadius: 6)
    )
    .accessibilityAddTraits(summaryInstructionsTab == tab ? .isSelected : [])
    .accessibilityIdentifier("settings.summaryInstructions.\(tab.rawValue)Tab")
  }

  private var account: some View {
    VStack(spacing: 0) {
      pageHeader(
        title: "Backup & Restore",
        subtitle: "Backup and synchronization"
      )

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
              ZStack(alignment: .bottomTrailing) {
                Image(systemName: "folder.fill")
                  .font(.system(size: 30))
                  .foregroundStyle(
                    controller.syncFolderStatus.isAvailable ? Color.accentColor : Color.secondary
                  )

                if controller.syncFolderStatus.isAvailable {
                  Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .background(Circle().fill(Color.green))
                    .offset(x: 3, y: 3)
                }
              }
              .frame(width: 38, height: 34)
              .accessibilityHidden(true)

              VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                  Text(controller.syncFolderStatus.title)
                    .font(.headline)
                    .accessibilityIdentifier("account.syncFolderStatus")

                  if controller.syncFolderStatus.isAvailable {
                    Text("CONNECTED")
                      .font(.caption2.weight(.bold))
                      .foregroundStyle(.green)
                      .padding(.horizontal, 7)
                      .padding(.vertical, 3)
                      .background(Color.green.opacity(0.12), in: Capsule())
                      .accessibilityLabel("Connected")
                      .accessibilityIdentifier("account.syncFolderConnected")
                  }
                }

                Text(controller.syncFolderStatus.detail)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }

              Spacer()

              if controller.isSyncSettingsSyncing {
                ProgressView()
                  .controlSize(.small)
                  .accessibilityLabel("Syncing settings")
              }
            }

            Button(
              controller.syncFolderStatus.isAvailable ? "Change Cloud Location" : "Choose Cloud Location",
              systemImage: "folder.fill"
            ) {
              controller.chooseSyncFolder()
            }
            .accessibilityIdentifier("account.chooseSyncFolder")

            Text(controller.syncFolderStatus.guidance)
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
          .padding(20)
          .background {
            RoundedRectangle(cornerRadius: 12)
              .fill(Color(nsColor: .textBackgroundColor))
              .overlay {
                RoundedRectangle(cornerRadius: 12)
                  .stroke(
                    controller.syncFolderStatus.isAvailable
                      ? Color.green.opacity(0.45)
                      : Color.clear,
                    lineWidth: 1
                  )
              }
          }

          VStack(alignment: .leading, spacing: 14) {
            Label("Settings", systemImage: "gearshape.2")
              .font(.title3.weight(.semibold))
              .accessibilityIdentifier("account.syncSettings")

            Text("Settings sync automatically through the chosen cloud-synced shared folder.")
              .foregroundStyle(.secondary)

            Label(controller.syncSettingsStatusText, systemImage: "arrow.triangle.2.circlepath")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(20)
          .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
          )

          VStack(alignment: .leading, spacing: 14) {
            Label("Recording Backup", systemImage: "icloud.and.arrow.up")
              .font(.title3.weight(.semibold))
              .accessibilityIdentifier("account.recordingBackup")

            Text(
              "Save recording audio, transcripts, speaker details, and summaries to the chosen "
                + "cloud-synced shared folder."
            )
            .foregroundStyle(.secondary)

            Toggle("Automatically back up recording changes", isOn: $controller.automaticRecordingBackupEnabled)
              .toggleStyle(.switch)
              .accessibilityIdentifier("account.automaticRecordingBackup")

            HStack(spacing: 7) {
              if controller.isAutomaticRecordingBackupRunning {
                ProgressView()
                  .controlSize(.small)
              }
              Label(
                controller.automaticRecordingBackupStatusText,
                systemImage: controller.automaticRecordingBackupEnabled
                  ? "arrow.triangle.2.circlepath.icloud"
                  : "pause.circle"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("account.automaticRecordingBackupStatus")
            }

            if controller.isRecordingBackupInProgress {
              ProgressView(value: controller.recordingBackupProgress)
                .accessibilityLabel("Recording backup progress")
            }

            HStack(spacing: 12) {
              Button("Back Up Now", systemImage: "icloud.and.arrow.up") {
                controller.backUpRecordings()
              }
              .disabled(
                controller.isRecordingBackupInProgress
                  || controller.isAutomaticRecordingBackupRunning
                  || !controller.syncFolderStatus.isAvailable
                  || controller.recordings.isEmpty
              )
              .accessibilityIdentifier("account.backUpNow")

              Text(
                controller.recordings.isEmpty
                  ? "No recordings on this Mac"
                  : "\(controller.recordings.count) recording\(controller.recordings.count == 1 ? "" : "s")"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }

            Label(controller.recordingBackupStatusText, systemImage: "clock.arrow.circlepath")
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("account.recordingBackupStatus")

            Text("Automatic backup is off by default. Local recordings are never removed or changed.")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
          .padding(20)
          .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
          )

          VStack(alignment: .leading, spacing: 14) {
            HStack {
              Label("Restore Recordings", systemImage: "icloud.and.arrow.down")
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("account.recordingRestore")

              Spacer()

              Button("Refresh", systemImage: "arrow.clockwise") {
                controller.refreshSyncFolderRecordingBackups()
              }
              .disabled(
                controller.isSyncFolderBackupsLoading
                  || controller.isRecordingRestoreInProgress
                  || controller.isAutomaticRecordingBackupRunning
                  || !controller.syncFolderStatus.isAvailable
              )
              .accessibilityIdentifier("account.refreshBackups")

              Button("Restore All", systemImage: "square.and.arrow.down") {
                controller.restoreAllRecordings()
              }
              .disabled(
                controller.isRecordingRestoreInProgress
                  || controller.isAutomaticRecordingBackupRunning
                  || controller.isRecordingBackupInProgress
                  || controller.syncFolderRecordingBackups.isEmpty
                  || controller.syncFolderRecordingBackups.allSatisfy {
                    controller.isRecordingStoredLocally($0.recordingID)
                  }
              )
              .accessibilityIdentifier("account.restoreAll")
            }

            if controller.isSyncFolderBackupsLoading {
              ProgressView("Loading backups…")
                .controlSize(.small)
            } else if controller.isRecordingRestoreInProgress {
              ProgressView(value: controller.recordingRestoreProgress)
                .accessibilityLabel("Recording restore progress")
            }

            Label(controller.recordingRestoreStatusText, systemImage: "externaldrive.badge.icloud")
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("account.recordingRestoreStatus")

            if !controller.syncFolderRecordingBackups.isEmpty {
              Divider()

              ForEach(controller.syncFolderRecordingBackups) { backup in
                HStack(spacing: 12) {
                  Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                  VStack(alignment: .leading, spacing: 3) {
                    Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                      .font(.subheadline.weight(.medium))
                    Text(
                      "\(ByteCountFormatter.string(fromByteCount: backup.audioByteCount, countStyle: .file)) · "
                        + "Backed up \(backup.exportedAt.formatted(date: .abbreviated, time: .shortened))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  }

                  Spacer()

                  if controller.isRecordingStoredLocally(backup.recordingID) {
                    Label("On this Mac", systemImage: "checkmark.circle.fill")
                      .font(.caption)
                      .foregroundStyle(.green)
                  } else {
                    Button("Restore") {
                      controller.restoreRecording(backup)
                    }
                    .disabled(
                      controller.isRecordingRestoreInProgress
                        || controller.isAutomaticRecordingBackupRunning
                        || controller.isRecordingBackupInProgress
                    )
                    .accessibilityIdentifier("account.restore.\(backup.recordingID.uuidString)")
                  }
                }
                .padding(.vertical, 3)
              }
            }

            Text("Restore verifies every backup and skips recordings already stored on this Mac.")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
          .padding(20)
          .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
          )
        }
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(28)
      }
      .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
  }

  private var summaryModelProgress: some View {
    VStack(alignment: .leading, spacing: 5) {
      ProgressView(value: controller.summaryModelDownloadProgress)
      Text(
        controller.summaryModelDownloadProgress > 0
          ? "Downloading model… \(Int(controller.summaryModelDownloadProgress * 100))%"
          : "Preparing model download…"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var knownSpeakers: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Known Speakers")
          .font(.title2.bold())
          .accessibilityIdentifier("speakerProfiles.title")

        Spacer()

        Button("Add Speaker", systemImage: "plus") {
          beginSpeakerEnrollment(profile: nil)
        }
        .disabled(controller.isRecording)
        .accessibilityIdentifier("speakerProfiles.add")
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 17)

      Divider()

      ScrollView {
        VStack(spacing: 0) {
          if controller.speakerProfiles.isEmpty {
            Text("No known speakers yet. Add a voice sample or name a speaker in a transcript.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(16)
              .accessibilityIdentifier("speakerProfiles.empty")
          } else {
            ForEach(Array(sortedSpeakerProfiles.enumerated()), id: \.element.id) { index, profile in
              if index > 0 {
                Divider()
                  .padding(.leading, 16)
              }

              HStack(spacing: 12) {
                Image(systemName: "person.wave.2.fill")
                  .foregroundStyle(Color.accentColor)
                  .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                  Text(profile.name)
                    .font(.body.weight(.medium))
                  Text(sampleCountText(profile.sampleCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                  controller.toggleSpeakerSamplePlayback(profile.id)
                } label: {
                  Image(systemName: controller.playingSpeakerSampleID == profile.id ? "stop.fill" : "play.fill")
                    .font(.caption.weight(.semibold))
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(!controller.hasSpeakerSample(profile.id))
                .help(controller.hasSpeakerSample(profile.id) ? "Play voice sample" : "Add a voice sample to enable playback")
                .accessibilityLabel(controller.playingSpeakerSampleID == profile.id ? "Stop voice sample" : "Play voice sample")
                .accessibilityIdentifier("speakerProfile.play.\(profile.id.uuidString)")

                Menu {
                  Button("Add Voice Sample", systemImage: "mic.badge.plus") {
                    beginSpeakerEnrollment(profile: profile)
                  }
                  Button("Rename", systemImage: "pencil") {
                    speakerProfileNameDraft = profile.name
                    profileToRename = profile
                  }
                  Divider()
                  Button("Forget Speaker", systemImage: "person.crop.circle.badge.minus", role: .destructive) {
                    profileToForget = profile
                  }
                } label: {
                  Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Manage \(profile.name)")
                .accessibilityIdentifier("speakerProfile.manage.\(profile.id.uuidString)")
              }
              .padding(16)
              .accessibilityElement(children: .contain)
              .accessibilityIdentifier("speakerProfile.\(profile.id.uuidString)")
            }
          }
        }
        .background(
          Color(nsColor: .textBackgroundColor),
          in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(.separator.opacity(0.45))
        }
        .padding(28)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
      }
      .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
  }

  private var recordingDock: some View {
    HStack(spacing: 16) {
      HStack(spacing: 10) {
        Circle()
          .fill(statusColor)
          .frame(width: 8, height: 8)
          .shadow(color: statusColor.opacity(0.35), radius: 3)

        VStack(alignment: .leading, spacing: 2) {
          Text(controller.statusText)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
          Text(
            controller.isFinalizingRecording
              ? "Finishing on device"
              : controller.isRecording ? "Recording locally" : "On-device · Private"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        if controller.isLoadingModel {
          ProgressView(value: controller.downloadProgress)
            .frame(width: 120)
            .padding(.leading, 4)
        }
      }

      Spacer(minLength: 0)

      if controller.isFinalizingRecording {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Finalizing recording")
      } else if controller.isRecording {
        HStack(spacing: 10) {
          Text(recordingElapsedTimeText)
            .font(.system(.body, design: .monospaced).weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .accessibilityLabel(recordingElapsedTimeText)
            .accessibilityIdentifier("recording.elapsed")

          LiveWaveformView(levels: controller.recentWaveformLevels)
            .frame(minWidth: 72, idealWidth: 260, maxWidth: 360)
            .frame(height: 34)
        }
        .layoutPriority(1)
      } else if controller.selectedSection == .home {
        Button("Clear", systemImage: "xmark") {
          controller.clearTranscript()
        }
        .disabled(controller.transcript.isEmpty)
      }

      Button {
        controller.audioButtonTapped()
      } label: {
        Label(
          controller.isRecording && !controller.isFinalizingRecording ? "Stop" : "Record",
          systemImage: controller.isRecording && !controller.isFinalizingRecording
            ? "stop.fill"
            : "mic.fill"
        )
        .font(.body.weight(.semibold))
        .frame(minWidth: 92)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(controller.isRecording && !controller.isFinalizingRecording ? .red : .accentColor)
      .disabled(controller.isLoadingModel || controller.isFinalizingRecording)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
    .background(.regularMaterial)
  }

  private var audioSourceDescription: String {
    switch controller.audioSourceMode {
    case .automatic:
      "Use Mac audio and microphone for a detected Zoom or Teams meeting; otherwise use the microphone."

    case .microphone:
      "Record voices heard by the selected microphone."

    case .meetingAudio:
      "Record audio played by this Mac, including Zoom or Teams."

    case .meetingAndMicrophone:
      "Record meeting participants and your microphone together."
    }
  }

  private func sidebarButton(
    _ title: String,
    systemImage: String,
    section: MacSection
  ) -> some View {
    let isSelected = controller.selectedSection == section

    return Button {
      controller.select(section)
    } label: {
      Label(title, systemImage: systemImage)
        .font(.subheadline.weight(isSelected ? .semibold : .regular))
        .foregroundStyle(isSelected ? Color.accentColor : .primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(
          isSelected ? Color.accentColor.opacity(0.12) : .clear,
          in: RoundedRectangle(cornerRadius: 8)
        )
    }
    .buttonStyle(.plain)
  }

  private func pageHeader(title: String, subtitle: String) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.title2.bold())
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer()
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 17)
  }

  private func settingsSection(
    _ title: String,
    @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)

      content()
        .background(
          Color(nsColor: .textBackgroundColor),
          in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(.separator.opacity(0.45))
        }
    }
  }

  private func settingsRow(_ label: String, value: String) -> some View {
    HStack(spacing: 16) {
      Text(label)
        .font(.body.weight(.medium))
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
    }
    .padding(16)
  }

  private var recordingCountText: String {
    let count = controller.recordings.count
    return count == 1 ? "1 recording saved locally" : "\(count) recordings saved locally"
  }

  private var recordingElapsedTimeText: String {
    let totalSeconds = max(0, Int(controller.recordingElapsedTime.rounded(.down)))
    let hours = totalSeconds / 3600
    let minutes = totalSeconds % 3600 / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
      return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
  }

  private var statusColor: Color {
    if controller.isRecording {
      return .red
    }
    if controller.isLoadingModel {
      return .orange
    }
    if controller.isModelReady {
      return .green
    }
    return .secondary
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { controller.errorMessage != nil },
      set: {
        if !$0 {
          controller.errorMessage = nil
        }
      }
    )
  }

  private var renameProfileIsPresented: Binding<Bool> {
    Binding(
      get: { profileToRename != nil },
      set: {
        if !$0 {
          profileToRename = nil
          speakerProfileNameDraft = ""
        }
      }
    )
  }

  private var forgetProfileIsPresented: Binding<Bool> {
    Binding(
      get: { profileToForget != nil },
      set: {
        if !$0 {
          profileToForget = nil
        }
      }
    )
  }

  private var sortedSpeakerProfiles: [SpeakerProfile] {
    controller.speakerProfiles.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private func beginSpeakerEnrollment(profile: SpeakerProfile?) {
    speakerEnrollmentName = profile?.name ?? ""
    speakerEnrollmentRequest = SpeakerEnrollmentRequest(profileID: profile?.id)
  }

  private func speakerEnrollmentSheet(_ request: SpeakerEnrollmentRequest) -> some View {
    VStack(alignment: .leading, spacing: 22) {
      VStack(alignment: .leading, spacing: 5) {
        Text(request.profileID == nil ? "Add Speaker" : "Add Voice Sample")
          .font(.title2.bold())
        Text("The voice sample is processed and stored locally for playback.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      TextField("Speaker name", text: $speakerEnrollmentName)
        .textFieldStyle(.roundedBorder)
        .disabled(request.profileID != nil || controller.isRecordingSpeakerSample || controller.isProcessingSpeakerSample)
        .accessibilityIdentifier("speakerEnrollment.name")

      VStack(spacing: 14) {
        Image(systemName: controller.isRecordingSpeakerSample ? "waveform.circle.fill" : "person.wave.2")
          .font(.system(size: 46))
          .foregroundStyle(controller.isRecordingSpeakerSample ? Color.red : Color.accentColor)

        Text(speakerEnrollmentStatusTitle)
          .font(.headline)

        Text(speakerEnrollmentStatusDetail)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)

        if controller.isProcessingSpeakerSample {
          ProgressView()
        } else if controller.isRecordingSpeakerSample {
          VStack(spacing: 7) {
            ProgressView(
              value: controller.speakerSampleSpeechDuration,
              total: MacTranscriptionController.requiredSpeakerSampleSpeechDuration
            )
            .frame(width: 240)

            Text(speakerSampleProgressText)
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("speakerEnrollment.progress")
        } else {
          Button("Record Voice Sample", systemImage: "mic.fill") {
            Task {
              await controller.startSpeakerSampleRecording()
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(
            request.profileID == nil
              && speakerEnrollmentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          )
          .accessibilityIdentifier("speakerEnrollment.record")
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 12)

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) {
          controller.cancelSpeakerSampleRecording()
          speakerEnrollmentRequest = nil
        }
        .disabled(controller.isProcessingSpeakerSample)
      }
    }
    .padding(26)
    .frame(width: 460)
    .onChange(of: controller.speakerSampleSpeechDuration) { _, speechDuration in
      guard speechDuration >= MacTranscriptionController.requiredSpeakerSampleSpeechDuration,
            controller.isRecordingSpeakerSample
      else {
        return
      }
      Task {
        if await controller.stopSpeakerSampleRecording(
          name: speakerEnrollmentName,
          profileID: request.profileID
        ) {
          speakerEnrollmentRequest = nil
        }
      }
    }
  }

  private var speakerEnrollmentStatusTitle: String {
    if controller.isProcessingSpeakerSample {
      return "Creating voice profile…"
    }
    if controller.isRecordingSpeakerSample {
      if controller.isSpeakerSampleVoiceActive {
        let remaining = Int(ceil(max(
          MacTranscriptionController.requiredSpeakerSampleSpeechDuration
            - controller.speakerSampleSpeechDuration,
          0
        )))
        return "Keep talking — \(remaining) seconds remaining"
      }
      return controller.speakerSampleSpeechDuration > 0
        ? "Paused — waiting for speech…"
        : "Waiting for speech…"
    }
    return "Record 10 seconds"
  }

  private var speakerEnrollmentStatusDetail: String {
    if controller.isProcessingSpeakerSample {
      return "FluidAudio is checking the sample and extracting the voice profile."
    }
    if controller.isRecordingSpeakerSample {
      return controller.isSpeakerSampleVoiceActive
        ? "The countdown advances only while your voice is detected."
        : "Start speaking or move closer to the microphone."
    }
    return "The sample saves automatically after 10 seconds of detected speech."
  }

  private var speakerSampleProgressText: String {
    let recordedSeconds = min(
      controller.speakerSampleSpeechDuration,
      MacTranscriptionController.requiredSpeakerSampleSpeechDuration
    )
    return String(format: "%.1f of 10.0 seconds", recordedSeconds)
  }

  private func sampleCountText(_ count: Int) -> String {
    count == 1 ? "1 voice sample" : "\(count) voice samples"
  }

  private func duration(_ value: TimeInterval) -> String {
    let seconds = max(0, Int(value.rounded()))
    return String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
}

// MARK: - SummaryInstructionsTab

private enum SummaryInstructionsTab: String {
  case edit
  case preview
}

// MARK: - MarkdownText

private struct MarkdownText: View {
  enum Style: Equatable {
    case block
    case inline
  }

  private let source: String
  private let style: Style

  init(_ source: String, style: Style = .block) {
    self.source = source
    self.style = style
  }

  var body: some View {
    if style == .inline {
      Text(Self.inlineMarkdown(source))
    } else {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(Self.blocks(from: source).enumerated()), id: \.offset) { _, block in
          blockView(block)
        }
      }
    }
  }

  @ViewBuilder
  private func blockView(_ block: Block) -> some View {
    switch block {
    case let .paragraph(text):
      Text(Self.inlineMarkdown(text))
        .fixedSize(horizontal: false, vertical: true)

    case let .heading(level, text):
      Text(Self.inlineMarkdown(text))
        .font(headingFont(level))
        .fixedSize(horizontal: false, vertical: true)

    case let .unorderedList(items):
      VStack(alignment: .leading, spacing: 5) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            Text(Self.inlineMarkdown(item))
          }
        }
      }

    case let .orderedList(items):
      VStack(alignment: .leading, spacing: 5) {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index + 1).")
              .monospacedDigit()
            Text(Self.inlineMarkdown(item))
          }
        }
      }

    case let .quote(text):
      HStack(alignment: .top, spacing: 10) {
        Rectangle()
          .fill(.secondary.opacity(0.45))
          .frame(width: 3)
        Text(Self.inlineMarkdown(text))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

    case let .code(text):
      ScrollView(.horizontal) {
        Text(text)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .padding(10)
      }
      .background(
        Color(nsColor: .controlBackgroundColor),
        in: RoundedRectangle(cornerRadius: 6)
      )
    }
  }

  private func headingFont(_ level: Int) -> Font {
    switch level {
    case 1:
      .title2.bold()
    case 2:
      .title3.bold()
    default:
      .headline
    }
  }

  private static func inlineMarkdown(_ source: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(
      interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    return (try? AttributedString(markdown: source, options: options))
      ?? AttributedString(source)
  }

  private static func blocks(from source: String) -> [Block] {
    let lines = source.components(separatedBy: .newlines)
    var blocks: [Block] = []
    var paragraph: [String] = []
    var unorderedItems: [String] = []
    var orderedItems: [String] = []
    var quoteLines: [String] = []
    var codeLines: [String] = []
    var isInsideCodeBlock = false

    func flushTextBlocks() {
      if !paragraph.isEmpty {
        blocks.append(.paragraph(paragraph.joined(separator: " ")))
        paragraph.removeAll()
      }
      if !unorderedItems.isEmpty {
        blocks.append(.unorderedList(unorderedItems))
        unorderedItems.removeAll()
      }
      if !orderedItems.isEmpty {
        blocks.append(.orderedList(orderedItems))
        orderedItems.removeAll()
      }
      if !quoteLines.isEmpty {
        blocks.append(.quote(quoteLines.joined(separator: " ")))
        quoteLines.removeAll()
      }
    }

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if trimmed.hasPrefix("```") {
        if isInsideCodeBlock {
          blocks.append(.code(codeLines.joined(separator: "\n")))
          codeLines.removeAll()
        } else {
          flushTextBlocks()
        }
        isInsideCodeBlock.toggle()
        continue
      }

      if isInsideCodeBlock {
        codeLines.append(line)
        continue
      }

      if trimmed.isEmpty {
        flushTextBlocks()
        continue
      }

      if let heading = heading(in: trimmed) {
        flushTextBlocks()
        blocks.append(.heading(level: heading.level, text: heading.text))
      } else if let item = unorderedItem(in: trimmed) {
        if !paragraph.isEmpty || !orderedItems.isEmpty || !quoteLines.isEmpty {
          flushTextBlocks()
        }
        unorderedItems.append(item)
      } else if let item = orderedItem(in: trimmed) {
        if !paragraph.isEmpty || !unorderedItems.isEmpty || !quoteLines.isEmpty {
          flushTextBlocks()
        }
        orderedItems.append(item)
      } else if trimmed.hasPrefix(">") {
        if !paragraph.isEmpty || !unorderedItems.isEmpty || !orderedItems.isEmpty {
          flushTextBlocks()
        }
        quoteLines.append(
          String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        )
      } else {
        if !unorderedItems.isEmpty || !orderedItems.isEmpty || !quoteLines.isEmpty {
          flushTextBlocks()
        }
        paragraph.append(trimmed)
      }
    }

    if isInsideCodeBlock, !codeLines.isEmpty {
      blocks.append(.code(codeLines.joined(separator: "\n")))
    }
    flushTextBlocks()
    return blocks
  }

  private static func heading(in line: String) -> (level: Int, text: String)? {
    let markerCount = line.prefix(while: { $0 == "#" }).count
    guard (1 ... 6).contains(markerCount) else { return nil }
    let textStart = line.index(line.startIndex, offsetBy: markerCount)
    guard textStart < line.endIndex, line[textStart] == " " else { return nil }
    return (
      markerCount,
      String(line[line.index(after: textStart)...])
    )
  }

  private static func unorderedItem(in line: String) -> String? {
    for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
      return String(line.dropFirst(marker.count))
    }
    return nil
  }

  private static func orderedItem(in line: String) -> String? {
    guard let separator = line.firstIndex(of: " ") else { return nil }
    let marker = line[..<separator]
    guard marker.last == ".", marker.dropLast().allSatisfy(\.isNumber) else {
      return nil
    }
    return String(line[line.index(after: separator)...])
  }

  private enum Block {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(String)
  }
}

// MARK: - SpeakerRenameRequest

private struct SpeakerRenameRequest {
  let speakerID: String
  let recordingID: UUID?
}

// MARK: - SpeakerEnrollmentRequest

private struct SpeakerEnrollmentRequest: Identifiable {
  let id = UUID()
  let profileID: UUID?
}

// MARK: - SpeakerTurnPresentation

private enum SpeakerTurnPresentation {
  case canvas
  case recording
}

// MARK: - TranscriptCanvas

private enum TranscriptCanvas {
  static let bottomID = "transcript-canvas-bottom"
  static let coordinateSpace = "transcript-canvas-scroll"
  static let lineSpacing: CGFloat = 4
}

// MARK: - LiveWaveformView

private struct LiveWaveformView: View {
  let levels: [Float]

  var body: some View {
    Canvas { context, size in
      let horizontalPadding: CGFloat = 8
      let step: CGFloat = 3
      let drawableWidth = max(0, size.width - horizontalPadding * 2)
      let visibleCount = max(1, Int(drawableWidth / step))
      let visibleLevels = levels.suffix(visibleCount)
      let startX = max(
        horizontalPadding,
        size.width - horizontalPadding - CGFloat(visibleLevels.count) * step
      )

      var baseline = Path()
      baseline.move(to: CGPoint(x: horizontalPadding, y: size.height / 2))
      baseline.addLine(to: CGPoint(x: size.width - horizontalPadding, y: size.height / 2))
      context.stroke(baseline, with: .color(.secondary.opacity(0.16)), lineWidth: 1)

      for (index, level) in visibleLevels.enumerated() {
        let normalizedLevel = CGFloat(min(max(level, 0), 1))
        let height = max(2, normalizedLevel * (size.height - 8))
        let rect = CGRect(
          x: startX + CGFloat(index) * step,
          y: (size.height - height) / 2,
          width: 1.5,
          height: height
        )
        context.fill(
          Path(roundedRect: rect, cornerRadius: 0.75),
          with: .color(.red.opacity(0.82))
        )
      }
    }
    .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    .overlay(alignment: .trailing) {
      Capsule()
        .fill(.red.opacity(0.9))
        .frame(width: 2, height: 24)
        .padding(.trailing, 6)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Live audio waveform")
    .accessibilityIdentifier("recording.waveform")
  }
}

// MARK: - TranscriptBottomOffsetKey

private struct TranscriptBottomOffsetKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}
