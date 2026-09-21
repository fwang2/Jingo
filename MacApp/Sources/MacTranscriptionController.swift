import AppKit
import AVFoundation
import Combine
import FluidAudio
import Foundation
import HuggingFace
import MeetingSummaryCore
import MLX
import MLXAudioCore
import MLXAudioSTT
import MLXAudioVAD

// MARK: - MacSection

enum MacSection: Hashable {
  case home
  case recordings
  case speakers
  case account
  case settings
}

// MARK: - MacTranscriptionModel

enum MacTranscriptionModel: String, CaseIterable, Identifiable, Sendable {
  case parakeetUnifiedEN
  case qwen3ASR
  case whisperLargeV3Turbo

  var id: Self {
    self
  }

  var title: String {
    switch self {
    case .parakeetUnifiedEN:
      "Parakeet Unified EN · 320 ms"

    case .qwen3ASR:
      "Qwen3-ASR 1.7B · 4-bit"

    case .whisperLargeV3Turbo:
      "Whisper Large-v3-Turbo"
    }
  }

  var behaviorDescription: String {
    switch self {
    case .parakeetUnifiedEN:
      "Optimized for low-latency English with punctuation and capitalization."

    case .qwen3ASR:
      "Shows provisional text while you speak."

    case .whisperLargeV3Turbo:
      "Uses Silero VAD and adds stable text after each phrase."
    }
  }

  var modelID: String {
    switch self {
    case .parakeetUnifiedEN:
      "FluidInference/parakeet-unified-en-0.6b-coreml"

    case .qwen3ASR:
      "mlx-community/Qwen3-ASR-1.7B-4bit"

    case .whisperLargeV3Turbo:
      "mlx-community/whisper-large-v3-turbo"
    }
  }
}

// MARK: - MacRecording

struct MacRecording: Codable, Equatable, Identifiable {
  let id: UUID
  let createdAt: Date
  let fileName: String
  var duration: TimeInterval
  var transcript: String
  var speakerTurns: [MacSpeakerTurn]?
  var speakerNames: [String: String]?
  var speakerEmbeddings: [String: [Float]]?
  var speakerProfileIDs: [String: UUID]?
  var summary: MeetingSummary? = nil
}

// MARK: - MacFinalTranscription

private struct MacFinalTranscription: Sendable {
  let text: String
  let attributedText: String
  let speakerTurns: [MacSpeakerTurn]
  let speakerEmbeddings: [String: [Float]]
  let speakerProfileIDs: [String: UUID]
  let speakerNames: [String: String]
  let refinementError: String?
}

// MARK: - MacSpeakerCheckpoint

private struct MacSpeakerCheckpoint: Sendable {
  let text: String
  let speakerTurns: [MacSpeakerTurn]
  let speakerEmbeddings: [String: [Float]]
  let speakerProfileIDs: [String: UUID]
  let speakerNames: [String: String]
}

// MARK: - MacTranscriptionEvent

private enum MacTranscriptionEvent: Sendable {
  case text(String)
  case recordingMeter(elapsedTime: TimeInterval, level: Float)
  case speakerCheckpoint(MacSpeakerCheckpoint)
  case stopped(MacFinalTranscription)
  case failure(String)
}

// MARK: - MacRecordingMeter

private final class MacRecordingMeter: @unchecked Sendable {
  struct Snapshot: Sendable {
    let elapsedTime: TimeInterval
    let level: Float
  }

  private static let outputInterval: TimeInterval = 0.125

  private let lock = NSLock()
  private var elapsedTime: TimeInterval = 0
  private var pendingDuration: TimeInterval = 0
  private var pendingPeak: Float = 0

  func consume(_ buffer: AVAudioPCMBuffer) -> Snapshot? {
    let sampleRate = buffer.format.sampleRate
    guard sampleRate > 0 else { return nil }

    let duration = TimeInterval(buffer.frameLength) / sampleRate
    let level = Self.normalizedLevel(in: buffer)
    return lock.withLock {
      elapsedTime += duration
      pendingDuration += duration
      pendingPeak = max(pendingPeak, level)
      guard pendingDuration >= Self.outputInterval else { return nil }

      let snapshot = Snapshot(elapsedTime: elapsedTime, level: pendingPeak)
      pendingDuration.formTruncatingRemainder(dividingBy: Self.outputInterval)
      pendingPeak = 0
      return snapshot
    }
  }

  private static func normalizedLevel(in buffer: AVAudioPCMBuffer) -> Float {
    guard let channel = buffer.floatChannelData?.pointee else { return 0 }
    let count = Int(buffer.frameLength)
    guard count > 0 else { return 0 }

    var sumOfSquares: Float = 0
    for sample in UnsafeBufferPointer(start: channel, count: count) {
      sumOfSquares += sample * sample
    }
    let rms = sqrt(sumOfSquares / Float(count))
    let decibels = 20 * log10(max(rms, 0.000_001))
    return min(max((decibels + 55) / 45, 0), 1)
  }
}

// MARK: - MacStreamingAudioBuffer

private final class MacStreamingAudioBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var pendingSamples: [Float] = []
  private var allSamples: [Float] = []

  func reset() {
    lock.withLock {
      pendingSamples.removeAll(keepingCapacity: true)
      allSamples.removeAll(keepingCapacity: true)
    }
  }

  func append(_ samples: [Float]) {
    guard !samples.isEmpty else { return }
    lock.withLock {
      pendingSamples.append(contentsOf: samples)
      allSamples.append(contentsOf: samples)
    }
  }

  func drain() -> [Float] {
    lock.withLock {
      let samples = pendingSamples
      pendingSamples.removeAll(keepingCapacity: true)
      return samples
    }
  }

  func snapshot() -> [Float] {
    lock.withLock { allSamples }
  }

  func durationMS(sampleRate: Double) -> Int64 {
    lock.withLock {
      Int64((Double(allSamples.count) / sampleRate * 1000).rounded())
    }
  }
}

// MARK: - MacConfirmedTranscriptTimeline

private final class MacConfirmedTranscriptTimeline: @unchecked Sendable {
  struct Snapshot: Sendable {
    let text: String
    let chunks: [MacTranscriptionChunk]

    var endTimeMS: Int64 {
      chunks.last?.endTimeMS ?? 0
    }
  }

  private let lock = NSLock()
  private var confirmedText = ""
  private var chunks: [MacTranscriptionChunk] = []

  func reset() {
    lock.withLock {
      confirmedText = ""
      chunks = []
    }
  }

  func update(text: String, audioEndTimeMS: Int64) {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return }

    lock.withLock {
      guard cleaned != confirmedText else { return }
      let endTimeMS = max(audioEndTimeMS, 1)

      if !confirmedText.isEmpty, cleaned.hasPrefix(confirmedText) {
        let delta = String(cleaned.dropFirst(confirmedText.count))
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let startTimeMS = chunks.last?.endTimeMS ?? 0
        if !delta.isEmpty, endTimeMS > startTimeMS {
          chunks.append(MacTranscriptionChunk(
            text: delta,
            startTimeMS: startTimeMS,
            endTimeMS: endTimeMS,
            language: nil
          ))
        }
      } else {
        chunks = [MacTranscriptionChunk(
          text: cleaned,
          startTimeMS: 0,
          endTimeMS: endTimeMS,
          language: nil
        )]
      }
      confirmedText = cleaned
    }
  }

  func snapshot() -> Snapshot {
    lock.withLock { Snapshot(text: confirmedText, chunks: chunks) }
  }
}

// MARK: - MacSpeakerCheckpointState

private final class MacSpeakerCheckpointState: @unchecked Sendable {
  private let lock = NSLock()
  private var checkpoint: MacSpeakerCheckpoint?

  func reset() {
    lock.withLock { checkpoint = nil }
  }

  func update(_ checkpoint: MacSpeakerCheckpoint) {
    lock.withLock { self.checkpoint = checkpoint }
  }

  func snapshot() -> MacSpeakerCheckpoint? {
    lock.withLock { checkpoint }
  }
}

// MARK: - MacStreamingTranscriptState

private final class MacStreamingTranscriptState: @unchecked Sendable {
  private let lock = NSLock()
  private var confirmed = ""
  private var provisional = ""
  private var final = ""

  func reset() {
    lock.withLock {
      confirmed = ""
      provisional = ""
      final = ""
    }
  }

  func updateConfirmed(_ text: String) -> String {
    lock.withLock {
      confirmed = text
      return displayText
    }
  }

  func updateProvisional(_ text: String) -> String {
    lock.withLock {
      provisional = text
      return displayText
    }
  }

  func update(confirmed: String, provisional: String) -> String {
    lock.withLock {
      self.confirmed = confirmed
      self.provisional = provisional
      return displayText
    }
  }

  func finish(_ text: String) {
    lock.withLock {
      final = text
    }
  }

  func resolvedText() -> String {
    lock.withLock { final.isEmpty ? displayText : final }
  }

  private var displayText: String {
    [confirmed, provisional]
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}

// MARK: - MacSpeakerSampleRecorder

private actor MacSpeakerSampleRecorder {
  private static let averageSpeechThresholdDB: Float = -45
  private static let peakSpeechThresholdDB: Float = -35

  private var recorder: AVAudioRecorder?
  private var recordingURL: URL?

  func start() throws {
    cancel()
    let recordingURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("jingo-speaker-sample-\(UUID().uuidString).caf")
    let recorder = try AVAudioRecorder(
      url: recordingURL,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
      ]
    )
    recorder.isMeteringEnabled = true
    recorder.prepareToRecord()
    guard recorder.record() else {
      throw MacTranscriptionError.audioRecordingFailed
    }
    self.recorder = recorder
    self.recordingURL = recordingURL
  }

  func isVoiceActive() -> Bool {
    guard let recorder, recorder.isRecording else { return false }
    recorder.updateMeters()
    return recorder.averagePower(forChannel: 0) >= Self.averageSpeechThresholdDB
      || recorder.peakPower(forChannel: 0) >= Self.peakSpeechThresholdDB
  }

  func stop() -> URL? {
    recorder?.stop()
    recorder = nil
    defer { recordingURL = nil }
    return recordingURL
  }

  func cancel() {
    recorder?.stop()
    recorder = nil
    if let recordingURL {
      try? FileManager.default.removeItem(at: recordingURL)
    }
    recordingURL = nil
  }
}

// MARK: - MacTranscriptionController

@MainActor
final class MacTranscriptionController: ObservableObject {
  @Published var selectedSection = MacSection.home
  @Published var recordings: [MacRecording]
  @Published var transcript = ""
  @Published var speakerAttributedText = ""
  @Published var speakerTurns: [MacSpeakerTurn] = []
  @Published var speakerNames: [String: String] = [:]
  @Published private(set) var speakerProfiles: [SpeakerProfile]
  @Published private(set) var playingSpeakerSampleID: UUID?
  @Published var isRecordingSpeakerSample = false
  @Published var isProcessingSpeakerSample = false
  @Published private(set) var speakerSampleSpeechDuration: TimeInterval = 0
  @Published private(set) var isSpeakerSampleVoiceActive = false
  @Published var statusText = "Preparing transcription model…"
  @Published var downloadProgress = 0.0
  @Published var isLoadingModel = false
  @Published var isModelReady = false
  @Published var isRecording = false
  @Published private(set) var isFinalizingRecording = false
  @Published private(set) var recordingElapsedTime: TimeInterval = 0
  @Published private(set) var recentWaveformLevels: [Float] = []
  @Published var audioSourceMode: MacAudioSourceMode {
    didSet {
      UserDefaults.standard.set(audioSourceMode.rawValue, forKey: Self.audioSourceModeDefaultsKey)
    }
  }

  @Published var transcriptionModel: MacTranscriptionModel {
    didSet {
      guard transcriptionModel != oldValue else { return }
      UserDefaults.standard.set(
        transcriptionModel.rawValue,
        forKey: Self.transcriptionModelDefaultsKey
      )
      isModelReady = false
      downloadProgress = 0
      statusText = "Transcription model changed"
      prepareModelIfNeeded()
    }
  }

  @Published var isLiveTranscriptionEnabled: Bool {
    didSet {
      UserDefaults.standard.set(isLiveTranscriptionEnabled, forKey: Self.liveTranscriptionDefaultsKey)
      recordSyncSettingsChange()
      if isLiveTranscriptionEnabled {
        prepareModelIfNeeded()
      }
    }
  }

  @Published var isHandsFreeModeEnabled: Bool {
    didSet {
      UserDefaults.standard.set(
        isHandsFreeModeEnabled,
        forKey: Self.handsFreeModeDefaultsKey
      )
      if isHandsFreeModeEnabled {
        if !isLiveTranscriptionEnabled {
          isLiveTranscriptionEnabled = true
        }
        startHandsFreeIfNeeded()
      } else if isRecording {
        toggleRecording()
      }
    }
  }

  @Published var transcriptFontSize: Double {
    didSet {
      UserDefaults.standard.set(transcriptFontSize, forKey: Self.transcriptFontSizeDefaultsKey)
      recordSyncSettingsChange()
    }
  }

  @Published var automaticSummariesEnabled: Bool {
    didSet {
      UserDefaults.standard.set(
        automaticSummariesEnabled,
        forKey: Self.automaticSummariesDefaultsKey
      )
      recordSyncSettingsChange()
    }
  }

  @Published var automaticRecordingBackupEnabled: Bool {
    didSet {
      UserDefaults.standard.set(
        automaticRecordingBackupEnabled,
        forKey: Self.automaticRecordingBackupDefaultsKey
      )
      recordSyncSettingsChange()
      guard !isApplyingSyncSettings else { return }
      if automaticRecordingBackupEnabled {
        scheduleAutomaticRecordingBackup(recordingIDs: Set(recordings.map(\.id)))
      } else {
        stopAutomaticRecordingBackup()
      }
    }
  }

  @Published var customSummaryInstructions: String {
    didSet {
      UserDefaults.standard.set(
        customSummaryInstructions,
        forKey: Self.customSummaryInstructionsDefaultsKey
      )
      recordSyncSettingsChange()
    }
  }

  @Published private(set) var syncFolderStatus = MacSyncFolderStatus.checking
  @Published private(set) var syncSettingsStatusText = "Choose a sync folder"
  @Published private(set) var isSyncSettingsSyncing = false
  @Published private(set) var isRecordingBackupInProgress = false
  @Published private(set) var recordingBackupProgress = 0.0
  @Published private(set) var recordingBackupStatusText = "Not backed up"
  @Published private(set) var lastRecordingBackupAt: Date?
  @Published private(set) var isAutomaticRecordingBackupRunning = false
  @Published private(set) var automaticRecordingBackupStatusText = "Off"
  @Published private(set) var syncFolderRecordingBackups: [MacRecordingBackupItem] = []
  @Published private(set) var isSyncFolderBackupsLoading = false
  @Published private(set) var isRecordingRestoreInProgress = false
  @Published private(set) var recordingRestoreProgress = 0.0
  @Published private(set) var recordingRestoreStatusText = "Load backups to restore recordings"

  @Published private(set) var isPreparingSummaryModel = false
  @Published private(set) var isSummaryModelReady = false
  @Published private(set) var summaryModelStatusText = "Not prepared"
  @Published private(set) var summaryModelDownloadProgress = 0.0

  @Published var errorMessage: String?

  static let transcriptFontSizeRange = 11.0 ... 24.0
  static let requiredSpeakerSampleSpeechDuration: TimeInterval = 10
  private static let recentWaveformLevelLimit = 120

  private static let liveTranscriptionDefaultsKey = "mac.liveTranscriptionEnabled"
  private static let audioSourceModeDefaultsKey = "mac.audioSourceMode"
  private static let transcriptionModelDefaultsKey = "mac.transcriptionModel"
  private static let handsFreeModeDefaultsKey = "mac.handsFreeModeEnabled"
  private static let transcriptFontSizeDefaultsKey = "mac.transcriptFontSize"
  private static let automaticSummariesDefaultsKey = "mac.automaticSummariesEnabled"
  private static let automaticRecordingBackupDefaultsKey = "mac.automaticRecordingBackupEnabled"
  private static let customSummaryInstructionsDefaultsKey = "mac.customSummaryInstructions"
  private static let syncSettingsCacheDefaultsKey = "mac.iCloudSettingsCache"
  private static let syncDeviceIDDefaultsKey = "mac.iCloudDeviceID"
  private static let lastRecordingBackupDefaultsKey = "mac.lastRecordingBackupAt"
  private static let defaultTranscriptFontSize = 14.0

  private let engine = MacTranscriptionEngine()
  private let meetingSummarizer = MacMeetingSummarizer()
  private let recordingStore: MacRecordingStore
  private let syncFolderAccess: MacSyncFolderAccess
  private let syncSettingsStore: any MacSyncSettingsStoring
  private let recordingBackupStore: any MacRecordingBackupStoring
  private let speakerSampleRecorder = MacSpeakerSampleRecorder()
  private var speakerEmbeddings: [String: [Float]] = [:]
  private var speakerProfileIDs: [String: UUID] = [:]
  private var operationTask: Task<Void, Never>?
  private var pendingTranscriptUpdateTask: Task<Void, Never>?
  private var pendingTranscriptText: String?
  private var speakerSampleMonitoringTask: Task<Void, Never>?
  private var audioPlayer: AVAudioPlayer?
  private var speakerSamplePlaybackTask: Task<Void, Never>?
  private var summaryPreparationTask: Task<Void, Never>?
  private var summaryTasks: [UUID: Task<Void, Never>] = [:]
  private var summaryTaskTokens: [UUID: UUID] = [:]
  private var syncSettingsTask: Task<Void, Never>?
  private var recordingBackupTask: Task<Void, Never>?
  private var automaticRecordingBackupTask: Task<Void, Never>?
  private var automaticRecordingBackupTaskToken: UUID?
  private var pendingAutomaticBackupRecordingIDs: Set<UUID> = []
  private var syncFolderBackupCatalogTask: Task<Void, Never>?
  private var recordingRestoreTask: Task<Void, Never>?
  private var isApplyingSyncSettings = false
  private var activeRecording: MacRecording?
  private var displayedRecordingID: UUID?
  private var recordingStartedAt: Date?

  init(
    syncFolderAccess: MacSyncFolderAccess? = nil,
    syncSettingsStore: (any MacSyncSettingsStoring)? = nil,
    recordingBackupStore: (any MacRecordingBackupStoring)? = nil
  ) {
    let uiTestScenario = ProcessInfo.processInfo.environment["JINGO_UI_TEST_SCENARIO"]
    let recordingStore = MacRecordingStore(
      directory: uiTestScenario.map { _ in
        FileManager.default.temporaryDirectory
          .appendingPathComponent("Jingo-Mac-UI-Tests-(ProcessInfo.processInfo.processIdentifier)")
      }
    )
    let syncFolderAccess = syncFolderAccess ?? MacSyncFolderAccess()
    self.recordingStore = recordingStore
    self.syncFolderAccess = syncFolderAccess
    self.syncSettingsStore = syncSettingsStore ?? MacSyncSettingsStore(
      folderURLProvider: { syncFolderAccess.selectedFolderURL() }
    )
    self.recordingBackupStore = recordingBackupStore ?? MacRecordingBackupStore(
      folderURLProvider: { syncFolderAccess.selectedFolderURL() }
    )
    recordings = uiTestScenario == nil
      ? Self.markInterruptedSummaries(in: recordingStore.load())
      : []
    speakerProfiles = uiTestScenario == nil ? recordingStore.loadSpeakerProfiles() : []
    audioSourceMode = uiTestScenario == nil
      ? UserDefaults.standard.string(forKey: Self.audioSourceModeDefaultsKey)
        .flatMap(MacAudioSourceMode.init(rawValue:)) ?? .automatic
      : .automatic
    transcriptionModel = uiTestScenario == nil
      ? UserDefaults.standard.string(forKey: Self.transcriptionModelDefaultsKey)
        .flatMap(MacTranscriptionModel.init(rawValue:)) ?? .parakeetUnifiedEN
      : .qwen3ASR
    isLiveTranscriptionEnabled = uiTestScenario == nil
      ? UserDefaults.standard.object(forKey: Self.liveTranscriptionDefaultsKey) as? Bool ?? true
      : false
    isHandsFreeModeEnabled = uiTestScenario == nil
      ? UserDefaults.standard.object(forKey: Self.handsFreeModeDefaultsKey) as? Bool ?? false
      : false
    automaticSummariesEnabled = uiTestScenario == nil
      ? UserDefaults.standard.object(forKey: Self.automaticSummariesDefaultsKey) as? Bool ?? true
      : false
    automaticRecordingBackupEnabled = uiTestScenario == nil
      ? UserDefaults.standard.object(forKey: Self.automaticRecordingBackupDefaultsKey) as? Bool ?? false
      : false
    customSummaryInstructions = uiTestScenario == nil
      ? UserDefaults.standard.string(forKey: Self.customSummaryInstructionsDefaultsKey)
        ?? MacMeetingSummarizer.defaultCustomInstructions
      : ""
    let storedTranscriptFontSize = UserDefaults.standard.object(
      forKey: Self.transcriptFontSizeDefaultsKey
    ) as? Double ?? Self.defaultTranscriptFontSize
    transcriptFontSize = uiTestScenario == nil
      ? min(
        max(storedTranscriptFontSize, Self.transcriptFontSizeRange.lowerBound),
        Self.transcriptFontSizeRange.upperBound
      )
      : Self.defaultTranscriptFontSize
    lastRecordingBackupAt = uiTestScenario == nil
      ? UserDefaults.standard.object(forKey: Self.lastRecordingBackupDefaultsKey) as? Date
      : nil
    if let lastRecordingBackupAt {
      recordingBackupStatusText = "Last backed up \(lastRecordingBackupAt.formatted())"
    }
    automaticRecordingBackupStatusText = automaticRecordingBackupEnabled
      ? "Waiting for changes"
      : "Off"
    syncFolderStatus = uiTestScenario == nil
      ? syncFolderAccess.status()
      : .available(
        FileManager.default.temporaryDirectory.appendingPathComponent("Jingo")
      )
    syncSettingsStatusText = syncFolderStatus.isAvailable
      ? "Settings synced"
      : "Settings remain saved on this Mac"

    if let uiTestScenario {
      configureUITestScenario(uiTestScenario)
    }
  }

  func startSyncFolderSettings() {
    guard ProcessInfo.processInfo.environment["JINGO_UI_TEST_SCENARIO"] == nil else {
      syncFolderStatus = .available(
        FileManager.default.temporaryDirectory.appendingPathComponent("Jingo")
      )
      syncSettingsStatusText = "Settings synced"
      return
    }
    scheduleSyncSettings(delay: nil)
    if automaticRecordingBackupEnabled {
      scheduleAutomaticRecordingBackup(recordingIDs: Set(recordings.map(\.id)))
    }
  }

  func refreshSyncFolderIfNeeded() {
    guard ProcessInfo.processInfo.environment["JINGO_UI_TEST_SCENARIO"] == nil else {
      return
    }
    scheduleSyncSettings(delay: nil)
  }

  func chooseSyncFolder() {
    do {
      guard try syncFolderAccess.chooseFolder() != nil else {
        return
      }
      syncFolderStatus = syncFolderAccess.status()
      syncSettingsStatusText = "Syncing settings…"
      syncFolderRecordingBackups = []
      recordingRestoreStatusText = "Loading backups…"
      scheduleSyncSettings(delay: nil)
      if automaticRecordingBackupEnabled {
        scheduleAutomaticRecordingBackup(recordingIDs: Set(recordings.map(\.id)))
      }
    } catch {
      errorMessage = "Jingo could not remember the selected folder: \(error.localizedDescription)"
    }
  }

  func backUpRecordings() {
    guard !isRecordingBackupInProgress, !isAutomaticRecordingBackupRunning else { return }
    guard syncFolderStatus.isAvailable else {
      errorMessage = "Choose an available sync folder before backing up recordings."
      return
    }
    guard !recordings.isEmpty else {
      recordingBackupStatusText = "No recordings to back up"
      return
    }

    let sources: [MacRecordingBackupSource]
    do {
      sources = try recordingBackupSources(from: recordings)
    } catch {
      recordingBackupStatusText = "Backup could not start"
      errorMessage = "Jingo could not prepare the recording metadata: \(error.localizedDescription)"
      return
    }

    isRecordingBackupInProgress = true
    recordingBackupProgress = 0
    recordingBackupStatusText = "Preparing backup…"
    recordingBackupTask = Task { [weak self] in
      guard let self else { return }
      defer {
        isRecordingBackupInProgress = false
        recordingBackupTask = nil
      }

      do {
        let report = try await recordingBackupStore.backUp(sources) { progress in
          await self.updateRecordingBackupProgress(progress)
        }
        try Task.checkCancellation()

        let completedAt = Date()
        if report.failures.isEmpty {
          lastRecordingBackupAt = completedAt
          UserDefaults.standard.set(completedAt, forKey: Self.lastRecordingBackupDefaultsKey)
          recordingBackupStatusText = Self.recordingBackupCompletionText(report)
          Task { @MainActor [weak self] in
            self?.refreshSyncFolderRecordingBackups()
          }
        } else {
          recordingBackupStatusText =
            "Backup finished with \(report.failures.count) failed recording\(report.failures.count == 1 ? "" : "s")"
          let failure = report.failures[0]
          errorMessage = "\(failure.recordingName): \(failure.message)"
        }
      } catch is CancellationError {
        recordingBackupStatusText = "Backup cancelled"
      } catch {
        recordingBackupStatusText = "Backup failed"
        errorMessage = error.localizedDescription
      }
    }
  }

  private static func recordingBackupCompletionText(_ report: MacRecordingBackupReport) -> String {
    if report.uploadedCount == 0 {
      return "Backup is up to date (\(report.skippedCount) unchanged)"
    }
    if report.skippedCount == 0 {
      return "Backed up \(report.uploadedCount) recording\(report.uploadedCount == 1 ? "" : "s")"
    }
    return "Backed up \(report.uploadedCount); \(report.skippedCount) unchanged"
  }

  private func recordingBackupSources(
    from recordings: [MacRecording]
  ) throws -> [MacRecordingBackupSource] {
    try recordings.map { recording in
      let metadata = try MacRecordingBackupJSON.encode(recording)
      return MacRecordingBackupSource(
        id: recording.id,
        createdAt: recording.createdAt,
        displayName: recording.createdAt.formatted(date: .abbreviated, time: .shortened),
        originalAudioFileName: recording.fileName,
        metadata: metadata,
        audioURL: recordingStore.audioURL(for: recording)
      )
    }
  }

  private func updateRecordingBackupProgress(_ progress: MacRecordingBackupProgress) {
    recordingBackupProgress = progress.fractionCompleted
    recordingBackupStatusText =
      "Backing up \(progress.currentRecordingName)… \(progress.completedCount)/\(progress.totalCount)"
  }

  private func scheduleAutomaticRecordingBackup(
    recordingIDs: Set<UUID>,
    delay: Duration = .seconds(2)
  ) {
    guard automaticRecordingBackupEnabled,
          ProcessInfo.processInfo.environment["JINGO_UI_TEST_SCENARIO"] == nil
    else {
      return
    }
    pendingAutomaticBackupRecordingIDs.formUnion(recordingIDs)
    guard !pendingAutomaticBackupRecordingIDs.isEmpty else { return }
    if isAutomaticRecordingBackupRunning {
      automaticRecordingBackupStatusText = "Additional changes queued"
      return
    }

    automaticRecordingBackupTask?.cancel()
    let token = UUID()
    automaticRecordingBackupTaskToken = token
    automaticRecordingBackupStatusText = syncFolderStatus.isAvailable
      ? "Changes queued"
      : "Waiting for sync folder"
    automaticRecordingBackupTask = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
        guard !Task.isCancelled, let self,
              automaticRecordingBackupTaskToken == token
        else {
          return
        }
        let followUpDelay = await performAutomaticRecordingBackup()
        guard automaticRecordingBackupTaskToken == token else { return }
        automaticRecordingBackupTask = nil
        automaticRecordingBackupTaskToken = nil
        if let followUpDelay,
           automaticRecordingBackupEnabled,
           !pendingAutomaticBackupRecordingIDs.isEmpty {
          scheduleAutomaticRecordingBackup(recordingIDs: [], delay: followUpDelay)
        }
      } catch is CancellationError {
        return
      } catch {
        self?.automaticRecordingBackupStatusText = "Automatic backup failed"
      }
    }
  }

  private func performAutomaticRecordingBackup() async -> Duration? {
    guard automaticRecordingBackupEnabled else { return nil }
    guard syncFolderStatus.isAvailable else {
      automaticRecordingBackupStatusText = "Waiting for sync folder"
      return nil
    }
    guard !isRecording,
          !isRecordingBackupInProgress,
          !isRecordingRestoreInProgress
    else {
      automaticRecordingBackupStatusText = "Waiting for Jingo to become idle"
      return .seconds(5)
    }

    let recordingIDs = pendingAutomaticBackupRecordingIDs
    let changedRecordings = recordings.filter { recordingIDs.contains($0.id) }
    guard !changedRecordings.isEmpty else {
      pendingAutomaticBackupRecordingIDs.subtract(recordingIDs)
      automaticRecordingBackupStatusText = "Up to date"
      return nil
    }

    let sources: [MacRecordingBackupSource]
    do {
      sources = try recordingBackupSources(from: changedRecordings)
    } catch {
      automaticRecordingBackupStatusText = "Could not prepare automatic backup"
      return nil
    }

    pendingAutomaticBackupRecordingIDs.subtract(recordingIDs)
    isAutomaticRecordingBackupRunning = true
    automaticRecordingBackupStatusText =
      "Backing up \(sources.count) changed recording\(sources.count == 1 ? "" : "s")…"
    defer { isAutomaticRecordingBackupRunning = false }

    do {
      let report = try await recordingBackupStore.backUp(sources) { _ in }
      try Task.checkCancellation()
      let failedIDs = Set(report.failures.map(\.recordingID))
      pendingAutomaticBackupRecordingIDs.formUnion(failedIDs)
      if report.failures.isEmpty {
        let completedAt = Date()
        lastRecordingBackupAt = completedAt
        UserDefaults.standard.set(completedAt, forKey: Self.lastRecordingBackupDefaultsKey)
        automaticRecordingBackupStatusText = "Up to date · \(completedAt.formatted(date: .omitted, time: .shortened))"
        recordingBackupStatusText = Self.recordingBackupCompletionText(report)
        refreshSyncFolderRecordingBackups()
        return pendingAutomaticBackupRecordingIDs.isEmpty ? nil : .seconds(2)
      }
      automaticRecordingBackupStatusText =
        "\(report.failures.count) recording\(report.failures.count == 1 ? "" : "s") need attention"
      return nil
    } catch is CancellationError {
      if automaticRecordingBackupEnabled {
        pendingAutomaticBackupRecordingIDs.formUnion(recordingIDs)
      }
      return nil
    } catch {
      pendingAutomaticBackupRecordingIDs.formUnion(recordingIDs)
      automaticRecordingBackupStatusText = "Automatic backup failed"
      return nil
    }
  }

  private func stopAutomaticRecordingBackup() {
    automaticRecordingBackupTask?.cancel()
    automaticRecordingBackupTask = nil
    automaticRecordingBackupTaskToken = nil
    pendingAutomaticBackupRecordingIDs.removeAll()
    isAutomaticRecordingBackupRunning = false
    automaticRecordingBackupStatusText = "Off"
  }

  func refreshSyncFolderRecordingBackups() {
    guard !isSyncFolderBackupsLoading, !isRecordingRestoreInProgress else { return }
    guard ProcessInfo.processInfo.environment["JINGO_UI_TEST_SCENARIO"] == nil else {
      recordingRestoreStatusText = "No backups found"
      return
    }
    guard syncFolderStatus.isAvailable else {
      recordingRestoreStatusText = "Choose a sync folder to load backups"
      return
    }

    isSyncFolderBackupsLoading = true
    recordingRestoreStatusText = "Loading backups…"
    syncFolderBackupCatalogTask = Task { [weak self] in
      guard let self else { return }
      defer {
        isSyncFolderBackupsLoading = false
        syncFolderBackupCatalogTask = nil
      }
      do {
        let catalog = try await recordingBackupStore.loadBackups()
        try Task.checkCancellation()
        syncFolderRecordingBackups = catalog.items
        if catalog.items.isEmpty, catalog.failures.isEmpty {
          recordingRestoreStatusText = "No backups found"
        } else if catalog.failures.isEmpty {
          recordingRestoreStatusText =
            "\(catalog.items.count) backup\(catalog.items.count == 1 ? "" : "s") available"
        } else {
          recordingRestoreStatusText =
            "Loaded \(catalog.items.count); \(catalog.failures.count) invalid backup\(catalog.failures.count == 1 ? "" : "s") ignored"
          if let failure = catalog.failures.first {
            errorMessage = "Backup \(failure.packageName): \(failure.message)"
          }
        }
      } catch is CancellationError {
        return
      } catch {
        recordingRestoreStatusText = "Could not load backups"
        errorMessage = error.localizedDescription
      }
    }
  }

  func restoreRecording(_ item: MacRecordingBackupItem) {
    startRecordingRestore([item])
  }

  func restoreAllRecordings() {
    startRecordingRestore(syncFolderRecordingBackups)
  }

  func isRecordingStoredLocally(_ recordingID: UUID) -> Bool {
    recordings.contains { $0.id == recordingID }
  }

  private func startRecordingRestore(_ items: [MacRecordingBackupItem]) {
    guard !isRecordingRestoreInProgress,
          !isRecordingBackupInProgress,
          !isAutomaticRecordingBackupRunning
    else {
      return
    }
    guard syncFolderStatus.isAvailable else {
      errorMessage = "Choose an available sync folder before restoring recordings."
      return
    }
    guard !items.isEmpty else {
      recordingRestoreStatusText = "No backups to restore"
      return
    }

    isRecordingRestoreInProgress = true
    recordingRestoreProgress = 0
    recordingRestoreStatusText = "Preparing restore…"
    recordingRestoreTask = Task { [weak self] in
      guard let self else { return }
      defer {
        isRecordingRestoreInProgress = false
        recordingRestoreTask = nil
      }

      var restoredCount = 0
      var skippedCount = 0
      var failures: [String] = []
      for (index, item) in items.enumerated() {
        if Task.isCancelled {
          recordingRestoreStatusText = "Restore cancelled"
          return
        }
        recordingRestoreProgress = Double(index) / Double(items.count)
        recordingRestoreStatusText =
          "Restoring \(item.createdAt.formatted(date: .abbreviated, time: .shortened))… \(index)/\(items.count)"

        if isRecordingStoredLocally(item.recordingID) {
          skippedCount += 1
          continue
        }

        do {
          try await restoreRecording(item)
          restoredCount += 1
        } catch is CancellationError {
          recordingRestoreStatusText = "Restore cancelled"
          return
        } catch {
          failures.append(
            "\(item.createdAt.formatted(date: .abbreviated, time: .shortened)): \(error.localizedDescription)"
          )
        }
      }

      recordingRestoreProgress = 1
      recordingRestoreStatusText = Self.recordingRestoreCompletionText(
        restoredCount: restoredCount,
        skippedCount: skippedCount,
        failedCount: failures.count
      )
      if let firstFailure = failures.first {
        errorMessage = firstFailure
      }
    }
  }

  private func restoreRecording(_ item: MacRecordingBackupItem) async throws {
    let preparation = try await recordingBackupStore.prepareRestore(recordingID: item.recordingID)
    var recording = try MacRecordingBackupJSON.decode(MacRecording.self, from: preparation.metadata)
    guard recording.id == item.recordingID,
          recording.fileName == item.originalAudioFileName,
          recording.createdAt == item.createdAt
    else {
      throw MacRecordingBackupError.recordingMetadataMismatch
    }
    guard URL(fileURLWithPath: recording.fileName).lastPathComponent == recording.fileName,
          !recording.fileName.isEmpty
    else {
      throw MacRecordingBackupError.unsafeFileName
    }
    recording = Self.markInterruptedSummaries(in: [recording])[0]
    let destinationURL = try recordingStore.restoreDestinationURL(for: recording)
    try await recordingBackupStore.restoreAudio(from: preparation, to: destinationURL)

    do {
      var updatedRecordings = recordings
      updatedRecordings.append(recording)
      updatedRecordings.sort { $0.createdAt > $1.createdAt }
      try recordingStore.save(updatedRecordings)
      recordings = updatedRecordings
    } catch {
      try? recordingStore.removeRestoredAudio(at: destinationURL)
      throw error
    }
  }

  private static func recordingRestoreCompletionText(
    restoredCount: Int,
    skippedCount: Int,
    failedCount: Int
  ) -> String {
    var parts: [String] = []
    if restoredCount > 0 {
      parts.append("\(restoredCount) restored")
    }
    if skippedCount > 0 {
      parts.append("\(skippedCount) already on this Mac")
    }
    if failedCount > 0 {
      parts.append("\(failedCount) failed")
    }
    return parts.isEmpty ? "Nothing to restore" : parts.joined(separator: " · ")
  }

  private func recordSyncSettingsChange() {
    guard !isApplyingSyncSettings,
          ProcessInfo.processInfo.environment["JINGO_UI_TEST_SCENARIO"] == nil
    else {
      return
    }

    let settings = currentCloudSettings(markingChangesAt: Date())
    saveCachedCloudSettings(settings)
    scheduleSyncSettings(delay: .milliseconds(750))
  }

  private func scheduleSyncSettings(delay: Duration?) {
    syncSettingsTask?.cancel()
    syncSettingsTask = Task { [weak self] in
      do {
        if let delay {
          try await Task.sleep(for: delay)
        }
        try Task.checkCancellation()
        await self?.synchronizeSettings()
      } catch is CancellationError {
        return
      } catch {
        self?.syncSettingsStatusText = "Settings sync failed"
        self?.errorMessage = error.localizedDescription
      }
    }
  }

  private func synchronizeSettings() async {
    isSyncSettingsSyncing = true
    defer { isSyncSettingsSyncing = false }

    let folderStatus = await syncSettingsStore.folderStatus()
    guard !Task.isCancelled else {
      return
    }
    syncFolderStatus = folderStatus
    if folderStatus.isAvailable, automaticRecordingBackupEnabled {
      scheduleAutomaticRecordingBackup(recordingIDs: [])
    }
    if folderStatus.isAvailable, selectedSection == .account {
      refreshSyncFolderRecordingBackups()
    }
    guard folderStatus.isAvailable else {
      syncSettingsStatusText = "Settings remain saved on this Mac"
      return
    }

    do {
      let localSettings = currentCloudSettings()
      let remoteSettings = try await syncSettingsStore.loadSettings()
      try Task.checkCancellation()
      let mergedSettings = remoteSettings.map(localSettings.merged(with:)) ?? localSettings

      if mergedSettings != remoteSettings {
        try await syncSettingsStore.saveSettings(mergedSettings)
      }
      try Task.checkCancellation()

      saveCachedCloudSettings(mergedSettings)
      applySyncSettings(mergedSettings)
      syncSettingsStatusText = "Settings synced"
    } catch is CancellationError {
      return
    } catch {
      syncSettingsStatusText = "Settings sync failed"
      errorMessage = error.localizedDescription
    }
  }

  private func currentCloudSettings(markingChangesAt modifiedAt: Date? = nil) -> MacCloudSettings {
    let deviceID = syncDeviceID()
    var settings = loadCachedCloudSettings() ?? .legacy(
      liveTranscriptionEnabled: isLiveTranscriptionEnabled,
      transcriptFontSize: transcriptFontSize,
      automaticSummariesEnabled: automaticSummariesEnabled,
      customSummaryInstructions: customSummaryInstructions,
      automaticRecordingBackupEnabled: automaticRecordingBackupEnabled,
      deviceID: deviceID
    )
    settings.schemaVersion = MacCloudSettings.currentSchemaVersion
    guard let modifiedAt else {
      return settings
    }

    return settings.updating(
      liveTranscriptionEnabled: isLiveTranscriptionEnabled,
      transcriptFontSize: transcriptFontSize,
      automaticSummariesEnabled: automaticSummariesEnabled,
      customSummaryInstructions: customSummaryInstructions,
      automaticRecordingBackupEnabled: automaticRecordingBackupEnabled,
      modifiedAt: modifiedAt,
      deviceID: deviceID
    )
  }

  private func applySyncSettings(_ settings: MacCloudSettings) {
    isApplyingSyncSettings = true
    defer { isApplyingSyncSettings = false }
    let wasAutomaticRecordingBackupEnabled = automaticRecordingBackupEnabled

    isLiveTranscriptionEnabled = settings.liveTranscriptionEnabled.value
    transcriptFontSize = min(
      max(settings.transcriptFontSize.value, Self.transcriptFontSizeRange.lowerBound),
      Self.transcriptFontSizeRange.upperBound
    )
    automaticSummariesEnabled = settings.automaticSummariesEnabled.value
    customSummaryInstructions = settings.customSummaryInstructions.value
    automaticRecordingBackupEnabled = settings.automaticRecordingBackupEnabled.value
    if automaticRecordingBackupEnabled {
      scheduleAutomaticRecordingBackup(
        recordingIDs: wasAutomaticRecordingBackupEnabled ? [] : Set(recordings.map(\.id))
      )
    } else {
      stopAutomaticRecordingBackup()
    }
  }

  private func loadCachedCloudSettings() -> MacCloudSettings? {
    guard let data = UserDefaults.standard.data(forKey: Self.syncSettingsCacheDefaultsKey)
    else {
      return nil
    }
    return try? JSONDecoder().decode(MacCloudSettings.self, from: data)
  }

  private func saveCachedCloudSettings(_ settings: MacCloudSettings) {
    guard let data = try? JSONEncoder().encode(settings) else {
      return
    }
    UserDefaults.standard.set(data, forKey: Self.syncSettingsCacheDefaultsKey)
  }

  private func syncDeviceID() -> String {
    if let deviceID = UserDefaults.standard.string(forKey: Self.syncDeviceIDDefaultsKey) {
      return deviceID
    }
    let deviceID = UUID().uuidString
    UserDefaults.standard.set(deviceID, forKey: Self.syncDeviceIDDefaultsKey)
    return deviceID
  }

  private func configureUITestScenario(_ scenario: String) {
    statusText = "Ready"
    isModelReady = true

    switch scenario {
    case "settings-default-prompt":
      customSummaryInstructions = MacMeetingSummarizer.defaultCustomInstructions

    case "settings-markdown":
      customSummaryInstructions = "**Focus on decisions**"

    case "live":
      transcript = "This live transcript stays in the same canvas while words continue to arrive."
      isRecording = true
      recordingElapsedTime = 9
      recentWaveformLevels = Self.previewWaveformLevels
      statusText = "Listening and transcribing…"

    case "checkpoint":
      speakerAttributedText = "Welcome to the review. The checkpoint now separates the speakers."
      transcript = speakerAttributedText + " This newest sentence is still being transcribed."
      speakerTurns = [
        MacSpeakerTurn(
          speakerID: "speaker-1",
          startTimeMS: 0,
          endTimeMS: 3000,
          text: "Welcome to the review.",
          words: []
        ),
        MacSpeakerTurn(
          speakerID: "speaker-2",
          startTimeMS: 3000,
          endTimeMS: 7000,
          text: "The checkpoint now separates the speakers.",
          words: []
        ),
      ]
      isRecording = true
      recordingElapsedTime = 9
      recentWaveformLevels = Self.previewWaveformLevels
      statusText = "Listening and transcribing…"

    case "single-speaker":
      installUITestRecording(
        transcript: "The finalized transcript remains in place and keeps the same readable typography.",
        turns: [
          MacSpeakerTurn(
            speakerID: "speaker-1",
            startTimeMS: 1000,
            endTimeMS: 9000,
            text: "The finalized transcript remains in place and keeps the same readable typography.",
            words: []
          ),
        ],
        names: ["speaker-1": "Feiyi"]
      )

    case "multiple-speakers":
      installUITestRecording(
        transcript: "Welcome to the review. Thanks, let’s look at the new transcript canvas.",
        turns: [
          MacSpeakerTurn(
            speakerID: "speaker-1",
            startTimeMS: 0,
            endTimeMS: 4000,
            text: "Welcome to the review.",
            words: []
          ),
          MacSpeakerTurn(
            speakerID: "speaker-2",
            startTimeMS: 4000,
            endTimeMS: 10000,
            text: "Thanks, let’s look at the new transcript canvas.",
            words: []
          ),
        ],
        names: [
          "speaker-1": "Feiyi",
          "speaker-2": "Guest",
        ]
      )

    case "summary-failed":
      installUITestRecording(
        transcript: "The team approved the launch plan and assigned the final review.",
        turns: [
          MacSpeakerTurn(
            speakerID: "speaker-1",
            startTimeMS: 0,
            endTimeMS: 6000,
            text: "The team approved the launch plan and assigned the final review.",
            words: []
          ),
        ],
        names: ["speaker-1": "Feiyi"]
      )
      recordings[0].summary = MeetingSummary(
        status: .failed(message: "The local model is not prepared."),
        model: MacMeetingSummarizer.modelID,
        sourceFingerprint: MeetingSummary.fingerprint(for: recordings[0].transcript)
      )

    case "summary-markdown":
      installUITestRecording(
        transcript: "The team approved the launch plan and assigned the final review.",
        turns: [
          MacSpeakerTurn(
            speakerID: "speaker-1",
            startTimeMS: 0,
            endTimeMS: 6000,
            text: "The team approved the launch plan and assigned the final review.",
            words: []
          ),
        ],
        names: ["speaker-1": "Feiyi"]
      )
      recordings[0].summary = MeetingSummary(
        status: .completed,
        overview: "The **launch plan** was approved with a `local review`.",
        keyPoints: ["Review the [release plan](https://example.com)."],
        decisions: ["Ship the **approved** plan."],
        openItems: ["The launch date remains **open**."],
        participantContributions: ["**Feiyi** proposed the final review."],
        actionItems: [
          .init(task: "Publish the **final plan**.", owner: "Feiyi", sourceTurnIDs: ["T1"]),
        ],
        risksAndFollowUpQuestions: ["Confirm whether the reviewer is **available**."],
        highlights: [
          .init(text: "**Approval** recorded.", sourceTurnIDs: ["T1"]),
        ],
        meetingStatus: "The group **reached a decision** and moved to execution.",
        generatedAt: Date(),
        model: MacMeetingSummarizer.modelID,
        sourceFingerprint: MeetingSummary.fingerprint(for: recordings[0].transcript),
        promptVersion: MacMeetingSummarizer.promptVersion
      )

    case "speaker-management":
      let profileID = UUID(uuidString: "B29365B1-5DE8-416F-B5F8-92D44834FCF8")!
      speakerProfiles = [
        SpeakerProfile(
          id: profileID,
          name: "Feiyi",
          embedding: [1, 0],
          sampleCount: 2
        ),
      ]
      try? recordingStore.installUITestSpeakerSample(profileID: profileID)

    default:
      break
    }
  }

  private func installUITestRecording(
    transcript: String,
    turns: [MacSpeakerTurn],
    names: [String: String]
  ) {
    let recordingID = UUID(uuidString: "3C476724-2F61-4630-A237-411F9B460A76")!
    let recording = MacRecording(
      id: recordingID,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      fileName: "ui-test.caf",
      duration: Double(turns.last?.endTimeMS ?? 0) / 1000,
      transcript: transcript,
      speakerTurns: turns,
      speakerNames: names,
      speakerEmbeddings: nil,
      speakerProfileIDs: nil
    )

    recordings = [recording]
    self.transcript = transcript
    speakerAttributedText = transcript
    speakerTurns = turns
    speakerNames = names
    displayedRecordingID = recordingID
  }

  func prepareModelIfNeeded() {
    guard isLiveTranscriptionEnabled, !isModelReady, !isLoadingModel else { return }
    prepareModel()
  }

  func startHandsFreeIfNeeded() {
    guard isHandsFreeModeEnabled, !isRecording, !isLoadingModel else { return }
    guard isLiveTranscriptionEnabled else {
      isLiveTranscriptionEnabled = true
      return
    }
    guard isModelReady else {
      prepareModelIfNeeded()
      return
    }
    toggleRecording()
  }

  func prepareModel() {
    guard !isLoadingModel, !isModelReady else { return }

    operationTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await loadModel()
        startHandsFreeIfNeeded()
      } catch {
        errorMessage = error.localizedDescription
        statusText = "Model preparation failed"
      }
    }
  }

  func select(_ section: MacSection) {
    selectedSection = section
    if section == .account {
      refreshSyncFolderRecordingBackups()
    }
  }

  func audioButtonTapped() {
    selectedSection = .home
    guard !isFinalizingRecording else { return }
    if isRecording, isHandsFreeModeEnabled {
      isHandsFreeModeEnabled = false
      return
    }
    toggleRecording()
  }

  func toggleRecording() {
    guard !isFinalizingRecording else { return }
    if isRecording {
      isFinalizingRecording = true
      statusText = "Finalizing recording…"
      operationTask = Task { [weak self] in
        guard let self else { return }
        await engine.stopRecording(speakerProfiles: speakerProfiles)
      }
      return
    }

    guard !isLoadingModel else { return }
    statusText = "Starting recording…"

    operationTask = Task { [weak self] in
      guard let self else { return }
      do {
        if isLiveTranscriptionEnabled, !isModelReady {
          try await loadModel()
        }
        let audioSourceResolution = await resolveAudioSourceMode()
        let resolvedAudioSourceMode = audioSourceResolution.mode
        if resolvedAudioSourceMode.includesMicrophone {
          statusText = "Checking microphone access…"
          guard await Self.requestMicrophonePermission() else {
            throw MacTranscriptionError.microphonePermissionDenied
          }
        }

        statusText = resolvedAudioSourceMode.includesMeetingAudio
          ? "Opening Mac audio…"
          : "Opening microphone…"
        let recording = try recordingStore.makeRecording()
        activeRecording = recording
        displayedRecordingID = nil
        resetRecordingVisualization()
        cancelPendingTranscriptUpdate()
        transcript = ""
        speakerAttributedText = ""
        speakerTurns = []
        speakerNames = [:]
        speakerEmbeddings = [:]
        speakerProfileIDs = [:]

        try await engine.startRecording(
          recordingURL: recordingStore.audioURL(for: recording),
          audioSourceMode: resolvedAudioSourceMode,
          liveTranscriptionEnabled: isLiveTranscriptionEnabled,
          speakerProfiles: speakerProfiles
        ) { [weak self] event in
          guard let self else { return }
          switch event {
          case let .text(text):
            scheduleTranscriptUpdate(text)
          case let .recordingMeter(elapsedTime, level):
            recordingElapsedTime = elapsedTime
            recentWaveformLevels.append(level)
            if recentWaveformLevels.count > Self.recentWaveformLevelLimit {
              recentWaveformLevels.removeFirst(
                recentWaveformLevels.count - Self.recentWaveformLevelLimit
              )
            }
          case let .speakerCheckpoint(checkpoint):
            speakerAttributedText = checkpoint.text
            speakerTurns = checkpoint.speakerTurns
            speakerEmbeddings = checkpoint.speakerEmbeddings
            speakerProfileIDs = checkpoint.speakerProfileIDs
            speakerNames = checkpoint.speakerNames
          case let .stopped(result):
            flushPendingTranscriptUpdate()
            transcript = result.text.isEmpty ? transcript : result.text
            speakerAttributedText = result.attributedText
            speakerTurns = result.speakerTurns
            speakerEmbeddings = result.speakerEmbeddings
            speakerProfileIDs = result.speakerProfileIDs
            speakerNames = result.speakerNames
            let completedRecordingID = finishActiveRecording()
            isRecording = false
            isFinalizingRecording = false
            resetRecordingVisualization()
            if let refinementError = result.refinementError {
              errorMessage = "The final speaker refinement failed. The latest checkpoint was kept. \(refinementError)"
              statusText = "Ready · speaker refinement incomplete"
            } else {
              statusText = isModelReady ? "Ready" : "Ready to record"
            }
            if automaticSummariesEnabled, let completedRecordingID {
              generateSummary(for: completedRecordingID)
            }
          case let .failure(message):
            flushPendingTranscriptUpdate()
            errorMessage = message
            _ = finishActiveRecording()
            isRecording = false
            isFinalizingRecording = false
            resetRecordingVisualization()
            statusText = "Recording failed"
          }
        }
        recordingStartedAt = Date()
        isFinalizingRecording = false
        isRecording = true
        let recordingStatus = isLiveTranscriptionEnabled
          ? "Listening and transcribing"
          : "Recording"
        statusText = if let meetingName = audioSourceResolution.meetingName {
          "\(recordingStatus) · \(meetingName)"
        } else {
          "\(recordingStatus)…"
        }
      } catch {
        cancelPendingTranscriptUpdate()
        errorMessage = error.localizedDescription
        activeRecording = nil
        displayedRecordingID = nil
        recordingStartedAt = nil
        isRecording = false
        isFinalizingRecording = false
        resetRecordingVisualization()
        statusText = "Recording failed"
      }
    }
  }

  private func resolveAudioSourceMode() async -> (mode: MacAudioSourceMode, meetingName: String?) {
    guard audioSourceMode == .automatic else {
      return (audioSourceMode, nil)
    }
    statusText = "Looking for a Zoom or Teams meeting…"
    let detection = await MacMeetingDetector.detectActiveMeeting()
    return (
      audioSourceMode.resolved(detectedMeeting: detection != nil),
      detection?.provider.displayName
    )
  }

  func clearTranscript() {
    cancelPendingTranscriptUpdate()
    transcript = ""
    speakerAttributedText = ""
    speakerTurns = []
    speakerNames = [:]
    speakerEmbeddings = [:]
    speakerProfileIDs = [:]
    displayedRecordingID = nil
  }

  func prepareSummaryModel() {
    guard !isPreparingSummaryModel, !isSummaryModelReady else { return }
    isPreparingSummaryModel = true
    summaryModelDownloadProgress = 0
    summaryModelStatusText = "Preparing local model…"
    summaryPreparationTask = Task { [weak self] in
      guard let self else { return }
      defer {
        isPreparingSummaryModel = false
        summaryPreparationTask = nil
      }

      do {
        try await meetingSummarizer.prepareModel { [weak self] progress in
          Task { @MainActor [weak self] in
            self?.summaryModelDownloadProgress = min(max(progress, 0), 1)
          }
        }
        summaryModelDownloadProgress = 1
        isSummaryModelReady = true
        summaryModelStatusText = "Ready"
      } catch {
        summaryModelDownloadProgress = 0
        summaryModelStatusText = "Preparation failed"
        errorMessage = error.localizedDescription
      }
    }
  }

  func generateSummary(for recordingID: UUID) {
    guard let index = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
    let recording = recordings[index]
    let customSummaryInstructions = customSummaryInstructions
    guard !recording.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }

    summaryTasks[recordingID]?.cancel()
    let taskToken = UUID()
    summaryTaskTokens[recordingID] = taskToken
    recordings[index].summary = MeetingSummary(
      status: .queued,
      model: MacMeetingSummarizer.modelID,
      sourceFingerprint: MeetingSummary.fingerprint(for: recording.transcript),
      promptVersion: MacMeetingSummarizer.promptVersion
    )
    saveRecordingsReportingError()

    summaryTasks[recordingID] = Task { [weak self] in
      guard let self else { return }
      defer {
        if summaryTaskTokens[recordingID] == taskToken {
          summaryTasks[recordingID] = nil
          summaryTaskTokens[recordingID] = nil
        }
      }

      updateSummaryStatus(for: recordingID, status: .generating)
      if !isSummaryModelReady {
        isPreparingSummaryModel = true
        summaryModelDownloadProgress = 0
        summaryModelStatusText = "Preparing local model…"
      }

      do {
        try await meetingSummarizer.prepareModel { [weak self] progress in
          Task { @MainActor [weak self] in
            self?.summaryModelDownloadProgress = min(max(progress, 0), 1)
          }
        }
        summaryModelDownloadProgress = 1
        isPreparingSummaryModel = false
        isSummaryModelReady = true
        summaryModelStatusText = "Ready"
        guard !Task.isCancelled, summaryTaskTokens[recordingID] == taskToken else {
          return
        }

        let summary = try await meetingSummarizer.summarize(
          transcript: recording.transcript,
          turns: recording.speakerTurns ?? [],
          speakerNames: recording.speakerNames ?? [:],
          duration: recording.duration,
          customInstructions: customSummaryInstructions
        )
        guard !Task.isCancelled, summaryTaskTokens[recordingID] == taskToken else {
          return
        }
        isPreparingSummaryModel = false
        isSummaryModelReady = true
        summaryModelStatusText = "Ready"
        updateSummary(for: recordingID, summary: summary)
      } catch is CancellationError {
        if summaryTaskTokens[recordingID] == taskToken {
          isPreparingSummaryModel = false
        }
      } catch {
        guard !Task.isCancelled, summaryTaskTokens[recordingID] == taskToken else {
          return
        }
        isPreparingSummaryModel = false
        summaryModelDownloadProgress = 0
        summaryModelStatusText = isSummaryModelReady ? "Ready" : "Preparation failed"
        updateSummaryStatus(for: recordingID, status: .failed(message: error.localizedDescription))
      }
    }
  }

  func cancelSummary(for recordingID: UUID) {
    summaryTasks[recordingID]?.cancel()
    summaryTasks[recordingID] = nil
    summaryTaskTokens[recordingID] = nil
    updateSummaryStatus(for: recordingID, status: .failed(message: "Summary generation was canceled."))
  }

  private static func markInterruptedSummaries(in recordings: [MacRecording]) -> [MacRecording] {
    recordings.map { recording in
      var recording = recording
      switch recording.summary?.status {
      case .generating?, .queued?:
        recording.summary?.status = .failed(
          message: "Summary generation was interrupted. Please try again."
        )
      default:
        break
      }
      return recording
    }
  }

  private func updateSummaryStatus(for recordingID: UUID, status: MeetingSummary.Status) {
    guard let index = recordings.firstIndex(where: { $0.id == recordingID }),
          var summary = recordings[index].summary
    else {
      return
    }
    summary.status = status
    recordings[index].summary = summary
    let automaticBackupRecordingIDs: Set<UUID> = switch status {
    case .completed, .failed:
      [recordingID]

    case .generating, .queued:
      []
    }
    saveRecordingsReportingError(
      automaticBackupRecordingIDs: automaticBackupRecordingIDs
    )
  }

  private func updateSummary(for recordingID: UUID, summary: MeetingSummary) {
    guard let index = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
    recordings[index].summary = summary
    saveRecordingsReportingError(automaticBackupRecordingIDs: [recordingID])
  }

  private func saveRecordingsReportingError(
    automaticBackupRecordingIDs: Set<UUID> = []
  ) {
    do {
      try recordingStore.save(recordings)
      scheduleAutomaticRecordingBackup(recordingIDs: automaticBackupRecordingIDs)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func scheduleTranscriptUpdate(_ text: String) {
    pendingTranscriptText = text
    guard pendingTranscriptUpdateTask == nil else { return }

    // Present only the latest candidate from a burst of decoder corrections.
    pendingTranscriptUpdateTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled, let self else { return }
      presentPendingTranscriptUpdate()
    }
  }

  private func presentPendingTranscriptUpdate() {
    pendingTranscriptUpdateTask = nil
    guard let pendingTranscriptText else { return }
    self.pendingTranscriptText = nil
    transcript = pendingTranscriptText
  }

  private func flushPendingTranscriptUpdate() {
    pendingTranscriptUpdateTask?.cancel()
    pendingTranscriptUpdateTask = nil
    guard let pendingTranscriptText else { return }
    self.pendingTranscriptText = nil
    transcript = pendingTranscriptText
  }

  private func cancelPendingTranscriptUpdate() {
    pendingTranscriptUpdateTask?.cancel()
    pendingTranscriptUpdateTask = nil
    pendingTranscriptText = nil
  }

  private func resetRecordingVisualization() {
    recordingElapsedTime = 0
    recentWaveformLevels = []
  }

  private static let previewWaveformLevels: [Float] = [
    0.08, 0.14, 0.32, 0.58, 0.76, 0.48, 0.24, 0.12, 0.1, 0.18,
    0.4, 0.66, 0.5, 0.22, 0.1, 0.08, 0.16, 0.3, 0.72, 0.54,
    0.28, 0.12, 0.08, 0.2, 0.38, 0.6, 0.42, 0.18, 0.1, 0.08,
  ]

  func renameSpeaker(_ speakerID: String, to name: String, recordingID: UUID?) {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let targetID = recordingID ?? displayedRecordingID
    guard let targetID,
          let recordingIndex = recordings.firstIndex(where: { $0.id == targetID })
    else {
      return
    }

    var names = recordings[recordingIndex].speakerNames ?? [:]
    if trimmedName.isEmpty {
      names.removeValue(forKey: speakerID)
      var profileIDs = recordings[recordingIndex].speakerProfileIDs ?? [:]
      profileIDs.removeValue(forKey: speakerID)
      recordings[recordingIndex].speakerProfileIDs = profileIDs.isEmpty ? nil : profileIDs
    } else {
      names[speakerID] = trimmedName
      if let embedding = recordings[recordingIndex].speakerEmbeddings?[speakerID] {
        let linkedProfileID = recordings[recordingIndex].speakerProfileIDs?[speakerID]
        if let profileID = SpeakerProfileMatcher.enroll(
          name: trimmedName,
          embedding: embedding,
          linkedProfileID: linkedProfileID,
          profiles: &speakerProfiles
        ) {
          var profileIDs = recordings[recordingIndex].speakerProfileIDs ?? [:]
          profileIDs[speakerID] = profileID
          recordings[recordingIndex].speakerProfileIDs = profileIDs
        }
      }
    }
    recordings[recordingIndex].speakerNames = names.isEmpty ? nil : names
    if targetID == displayedRecordingID {
      speakerNames = names
      speakerProfileIDs = recordings[recordingIndex].speakerProfileIDs ?? [:]
    }

    do {
      try recordingStore.save(recordings)
      try recordingStore.saveSpeakerProfiles(speakerProfiles)
      scheduleAutomaticRecordingBackup(recordingIDs: [targetID])
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func startSpeakerSampleRecording() async {
    guard !isRecording, !isRecordingSpeakerSample, !isProcessingSpeakerSample else { return }
    do {
      guard await Self.requestMicrophonePermission() else {
        throw MacTranscriptionError.microphonePermissionDenied
      }
      try await speakerSampleRecorder.start()
      speakerSampleSpeechDuration = 0
      isSpeakerSampleVoiceActive = false
      isRecordingSpeakerSample = true
      startSpeakerSampleMonitoring()
      errorMessage = nil
    } catch {
      isRecordingSpeakerSample = false
      errorMessage = error.localizedDescription
    }
  }

  func stopSpeakerSampleRecording(name: String, profileID: UUID?) async -> Bool {
    guard isRecordingSpeakerSample,
          let sampleURL = await speakerSampleRecorder.stop()
    else {
      return false
    }
    speakerSampleMonitoringTask?.cancel()
    speakerSampleMonitoringTask = nil
    isRecordingSpeakerSample = false
    isSpeakerSampleVoiceActive = false
    isProcessingSpeakerSample = true
    defer {
      isProcessingSpeakerSample = false
      try? FileManager.default.removeItem(at: sampleURL)
    }

    do {
      let validatedName = try SpeakerProfileMatcher.validatedName(
        name,
        excluding: profileID,
        profiles: speakerProfiles
      )
      let embedding = try await engine.speakerEnrollmentEmbedding(from: sampleURL)
      guard let enrolledProfileID = SpeakerProfileMatcher.enroll(
        name: validatedName,
        embedding: embedding,
        linkedProfileID: profileID,
        profiles: &speakerProfiles
      ) else {
        throw SpeakerProfileEnrollmentError.missingEmbedding
      }
      try recordingStore.saveSpeakerSample(from: sampleURL, profileID: enrolledProfileID)
      try recordingStore.saveSpeakerProfiles(speakerProfiles)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func cancelSpeakerSampleRecording() {
    speakerSampleMonitoringTask?.cancel()
    speakerSampleMonitoringTask = nil
    isRecordingSpeakerSample = false
    isSpeakerSampleVoiceActive = false
    speakerSampleSpeechDuration = 0
    Task {
      await speakerSampleRecorder.cancel()
    }
  }

  private func startSpeakerSampleMonitoring() {
    speakerSampleMonitoringTask?.cancel()
    speakerSampleMonitoringTask = Task { @MainActor [weak self] in
      guard let self else { return }
      var previousUpdate = Date()

      while !Task.isCancelled, isRecordingSpeakerSample {
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled else { return }

        let currentUpdate = Date()
        let elapsed = min(currentUpdate.timeIntervalSince(previousUpdate), 0.25)
        previousUpdate = currentUpdate
        let isVoiceActive = await speakerSampleRecorder.isVoiceActive()
        guard isRecordingSpeakerSample else { return }

        isSpeakerSampleVoiceActive = isVoiceActive
        if isVoiceActive {
          speakerSampleSpeechDuration = min(
            Self.requiredSpeakerSampleSpeechDuration,
            speakerSampleSpeechDuration + elapsed
          )
        }
      }
    }
  }

  func renameSpeakerProfile(_ profileID: UUID, to name: String) {
    do {
      let updatedName = try SpeakerProfileMatcher.rename(
        profileID: profileID,
        to: name,
        profiles: &speakerProfiles
      )
      var changedRecordingIDs: Set<UUID> = []
      for index in recordings.indices {
        let linkedSpeakerIDs = recordings[index].speakerProfileIDs?
          .filter { $0.value == profileID }
          .map(\.key) ?? []
        guard !linkedSpeakerIDs.isEmpty else { continue }
        var names = recordings[index].speakerNames ?? [:]
        for speakerID in linkedSpeakerIDs {
          names[speakerID] = updatedName
        }
        recordings[index].speakerNames = names
        changedRecordingIDs.insert(recordings[index].id)
      }
      refreshDisplayedSpeakerMetadata()
      try saveSpeakerData()
      scheduleAutomaticRecordingBackup(recordingIDs: changedRecordingIDs)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func forgetSpeakerProfile(_ profileID: UUID) {
    if playingSpeakerSampleID == profileID {
      stopSpeakerSamplePlayback()
    }
    do {
      try recordingStore.deleteSpeakerSample(profileID: profileID)
    } catch {
      errorMessage = error.localizedDescription
      return
    }
    speakerProfiles.removeAll { $0.id == profileID }
    var changedRecordingIDs: Set<UUID> = []
    for index in recordings.indices {
      guard var profileIDs = recordings[index].speakerProfileIDs else { continue }
      profileIDs = profileIDs.filter { $0.value != profileID }
      recordings[index].speakerProfileIDs = profileIDs.isEmpty ? nil : profileIDs
      changedRecordingIDs.insert(recordings[index].id)
    }
    speakerProfileIDs = speakerProfileIDs.filter { $0.value != profileID }
    do {
      try saveSpeakerData()
      scheduleAutomaticRecordingBackup(recordingIDs: changedRecordingIDs)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func play(_ recording: MacRecording, at startTimeMS: Int64 = 0) {
    do {
      stopSpeakerSamplePlayback()
      let player = try AVAudioPlayer(contentsOf: recordingStore.audioURL(for: recording))
      player.currentTime = max(0, Double(startTimeMS) / 1000)
      player.prepareToPlay()
      player.play()
      audioPlayer = player
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func hasSpeakerSample(_ profileID: UUID) -> Bool {
    recordingStore.speakerSampleURL(profileID: profileID) != nil
  }

  func toggleSpeakerSamplePlayback(_ profileID: UUID) {
    if playingSpeakerSampleID == profileID {
      stopSpeakerSamplePlayback()
      return
    }

    do {
      guard let sampleURL = recordingStore.speakerSampleURL(profileID: profileID) else {
        return
      }
      stopSpeakerSamplePlayback()
      audioPlayer?.stop()
      let player = try AVAudioPlayer(contentsOf: sampleURL)
      player.prepareToPlay()
      guard player.play() else {
        throw MacTranscriptionError.audioPlaybackFailed
      }
      audioPlayer = player
      playingSpeakerSampleID = profileID
      speakerSamplePlaybackTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(player.duration))
        guard !Task.isCancelled, self?.playingSpeakerSampleID == profileID else { return }
        self?.playingSpeakerSampleID = nil
      }
    } catch {
      stopSpeakerSamplePlayback()
      errorMessage = error.localizedDescription
    }
  }

  private func stopSpeakerSamplePlayback() {
    speakerSamplePlaybackTask?.cancel()
    speakerSamplePlaybackTask = nil
    audioPlayer?.stop()
    audioPlayer = nil
    playingSpeakerSampleID = nil
  }

  private func loadModel() async throws {
    isLoadingModel = true
    downloadProgress = 0
    statusText = "Preparing transcription model…"
    defer { isLoadingModel = false }

    try await engine.loadModel(transcriptionModel) { [weak self] progress in
      self?.downloadProgress = progress
      self?.statusText = progress < 1
        ? "Downloading model · \(Int(progress * 100))%"
        : "Loading model…"
    }
    isModelReady = true
    statusText = "Ready"
  }

  private func finishActiveRecording() -> UUID? {
    guard var recording = activeRecording else { return nil }
    recording.transcript = transcript
    recording.speakerTurns = speakerTurns
    recording.speakerNames = speakerNames.isEmpty ? nil : speakerNames
    recording.speakerEmbeddings = speakerEmbeddings.isEmpty ? nil : speakerEmbeddings
    recording.speakerProfileIDs = speakerProfileIDs.isEmpty ? nil : speakerProfileIDs
    recording.duration = Date().timeIntervalSince(recordingStartedAt ?? recording.createdAt)
    recordings.insert(recording, at: 0)
    displayedRecordingID = recording.id
    do {
      try recordingStore.save(recordings)
      scheduleAutomaticRecordingBackup(recordingIDs: [recording.id])
    } catch {
      errorMessage = error.localizedDescription
    }
    activeRecording = nil
    recordingStartedAt = nil
    return recording.id
  }

  private func refreshDisplayedSpeakerMetadata() {
    guard let displayedRecordingID,
          let recording = recordings.first(where: { $0.id == displayedRecordingID })
    else {
      return
    }
    speakerNames = recording.speakerNames ?? [:]
    speakerProfileIDs = recording.speakerProfileIDs ?? [:]
  }

  private func saveSpeakerData() throws {
    try recordingStore.save(recordings)
    try recordingStore.saveSpeakerProfiles(speakerProfiles)
  }

  private static func requestMicrophonePermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .audio)
    case .denied, .restricted:
      return false
    @unknown default:
      return false
    }
  }
}

// MARK: - MacRecordingStore

private struct MacRecordingStore: Sendable {
  private let directory: URL
  private let indexURL: URL
  private let speakerProfilesURL: URL
  private let speakerSamplesDirectory: URL

  init(directory: URL? = nil) {
    self.directory = directory
      ?? URL.applicationSupportDirectory.appendingPathComponent("Jingo/Recordings", isDirectory: true)
    indexURL = self.directory.appendingPathComponent("recordings.json")
    speakerProfilesURL = self.directory.appendingPathComponent("speaker-profiles.json")
    speakerSamplesDirectory = self.directory.appendingPathComponent("Speaker Samples", isDirectory: true)
  }

  func load() -> [MacRecording] {
    guard let data = try? Data(contentsOf: indexURL) else { return [] }
    return (try? JSONDecoder().decode([MacRecording].self, from: data)) ?? []
  }

  func makeRecording() throws -> MacRecording {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let id = UUID()
    return MacRecording(
      id: id,
      createdAt: Date(),
      fileName: "\(id.uuidString).caf",
      duration: 0,
      transcript: "",
      speakerTurns: nil,
      speakerNames: nil,
      speakerEmbeddings: nil,
      speakerProfileIDs: nil
    )
  }

  func audioURL(for recording: MacRecording) -> URL {
    directory.appendingPathComponent(recording.fileName)
  }

  func restoreDestinationURL(for recording: MacRecording) throws -> URL {
    guard !recording.fileName.isEmpty,
          recording.fileName != ".",
          recording.fileName != "..",
          URL(fileURLWithPath: recording.fileName).lastPathComponent == recording.fileName
    else {
      throw MacRecordingBackupError.unsafeFileName
    }
    let destinationURL = directory.appendingPathComponent(recording.fileName)
    guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
      throw MacRecordingBackupError.audioDestinationExists
    }
    return destinationURL
  }

  func removeRestoredAudio(at url: URL) throws {
    guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
          FileManager.default.fileExists(atPath: url.path)
    else {
      return
    }
    try FileManager.default.removeItem(at: url)
  }

  func save(_ recordings: [MacRecording]) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(recordings)
    try data.write(to: indexURL, options: .atomic)
  }

  func loadSpeakerProfiles() -> [SpeakerProfile] {
    guard let data = try? Data(contentsOf: speakerProfilesURL) else { return [] }
    return (try? JSONDecoder().decode([SpeakerProfile].self, from: data)) ?? []
  }

  func saveSpeakerProfiles(_ profiles: [SpeakerProfile]) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(profiles)
    try data.write(to: speakerProfilesURL, options: .atomic)
  }

  func speakerSampleURL(profileID: UUID) -> URL? {
    let url = speakerSampleFileURL(profileID: profileID)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  func saveSpeakerSample(from sourceURL: URL, profileID: UUID) throws {
    try FileManager.default.createDirectory(at: speakerSamplesDirectory, withIntermediateDirectories: true)
    let destinationURL = speakerSampleFileURL(profileID: profileID)
    let stagedURL = speakerSamplesDirectory
      .appendingPathComponent(".\(profileID.uuidString)-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: stagedURL) }

    try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagedURL)
    } else {
      try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
    }
  }

  func deleteSpeakerSample(profileID: UUID) throws {
    let url = speakerSampleFileURL(profileID: profileID)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  private func speakerSampleFileURL(profileID: UUID) -> URL {
    speakerSamplesDirectory.appendingPathComponent("\(profileID.uuidString).caf")
  }

  #if DEBUG
    func installUITestSpeakerSample(profileID: UUID) throws {
      try FileManager.default.createDirectory(at: speakerSamplesDirectory, withIntermediateDirectories: true)
      let sampleURL = speakerSampleFileURL(profileID: profileID)
      if FileManager.default.fileExists(atPath: sampleURL.path) {
        try FileManager.default.removeItem(at: sampleURL)
      }
      let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
      let file = try AVAudioFile(
        forWriting: sampleURL,
        settings: format.settings
      )
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000)!
      buffer.frameLength = 96000
      try file.write(from: buffer)
    }
  #endif
}

// MARK: - MacMixedAudioConsumer

private final class MacMixedAudioConsumer: @unchecked Sendable {
  private let audioFile: AVAudioFile
  private let format: AVAudioFormat
  private let recordingMeter: MacRecordingMeter
  private let streamingAudioBuffer: MacStreamingAudioBuffer
  private let keepsTranscriptionAudio: Bool
  private let eventHandler: @MainActor @Sendable (MacTranscriptionEvent) -> Void
  private let failureHandler: @Sendable (String) -> Void

  init(
    audioFile: AVAudioFile,
    format: AVAudioFormat,
    recordingMeter: MacRecordingMeter,
    streamingAudioBuffer: MacStreamingAudioBuffer,
    keepsTranscriptionAudio: Bool,
    eventHandler: @escaping @MainActor @Sendable (MacTranscriptionEvent) -> Void,
    failureHandler: @escaping @Sendable (String) -> Void
  ) {
    self.audioFile = audioFile
    self.format = format
    self.recordingMeter = recordingMeter
    self.streamingAudioBuffer = streamingAudioBuffer
    self.keepsTranscriptionAudio = keepsTranscriptionAudio
    self.eventHandler = eventHandler
    self.failureHandler = failureHandler
  }

  func consume(_ samples: [Float]) {
    guard !samples.isEmpty,
          let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
          ),
          let channel = buffer.floatChannelData?.pointee
    else {
      return
    }

    buffer.frameLength = AVAudioFrameCount(samples.count)
    channel.update(from: samples, count: samples.count)

    do {
      try audioFile.write(from: buffer)
      if keepsTranscriptionAudio {
        streamingAudioBuffer.append(samples)
      }
      if let meter = recordingMeter.consume(buffer) {
        Task { @MainActor in
          eventHandler(.recordingMeter(
            elapsedTime: meter.elapsedTime,
            level: meter.level
          ))
        }
      }
    } catch {
      failureHandler(error.localizedDescription)
    }
  }
}

// MARK: - MacWhisperModelBundle

private final class MacWhisperModelBundle: @unchecked Sendable {
  let transcriptionModel: WhisperModel
  let vadModel: SileroVAD

  init(transcriptionModel: WhisperModel, vadModel: SileroVAD) {
    self.transcriptionModel = transcriptionModel
    self.vadModel = vadModel
  }
}

// MARK: - MacTranscriptionEngine

private actor MacTranscriptionEngine {
  static let sileroModelID = "mlx-community/silero-vad"
  static let sampleRate = 16000.0
  static let modelRootURL = URL.applicationSupportDirectory
    .appendingPathComponent("WhisperBoardMac/Models", isDirectory: true)

  private let executionPolicy = TranscriptionExecutionPolicy.automatic
  private lazy var speakerPipeline = MacSpeakerPipeline(modelRootURL: Self.modelRootURL)
  private var loadedTranscriptionModel: MacTranscriptionModel?
  private var parakeetModel: StreamingUnifiedAsrManager?
  private var qwenModel: Qwen3ASRModel?
  private var whisperModels: MacWhisperModelBundle?
  private var session: StreamingInferenceSession?
  private var isParakeetSessionActive = false
  private var isWhisperSessionActive = false
  private var audioEngine: AVAudioEngine?
  private var systemAudioCapture: MacSystemAudioCapture?
  private var audioMixer: MacRealtimeAudioMixer?
  private var mixedAudioConsumer: MacMixedAudioConsumer?
  private var recordingURL: URL?
  private let streamingAudioBuffer = MacStreamingAudioBuffer()
  private let streamingTranscriptState = MacStreamingTranscriptState()
  private let confirmedTranscriptTimeline = MacConfirmedTranscriptTimeline()
  private let checkpointState = MacSpeakerCheckpointState()
  private var feedTask: Task<Void, Never>?
  private var eventTask: Task<Void, Never>?
  private var checkpointTask: Task<Void, Never>?
  private var eventHandler: (@MainActor @Sendable (MacTranscriptionEvent) -> Void)?

  func loadModel(
    _ requestedModel: MacTranscriptionModel,
    progressHandler: @escaping @MainActor @Sendable (Double) -> Void
  ) async throws {
    if loadedTranscriptionModel == requestedModel,
       parakeetModel != nil || qwenModel != nil || whisperModels != nil {
      if executionPolicy.keepsAuxiliaryModelsResident {
        try await speakerPipeline.prepareModels { _ in }
      }
      await progressHandler(1)
      return
    }
    guard let repository = Repo.ID(rawValue: requestedModel.modelID) else {
      throw MacTranscriptionError.invalidModelIdentifier
    }

    if let parakeetModel {
      await parakeetModel.cleanup()
    }
    parakeetModel = nil
    qwenModel = nil
    whisperModels = nil
    loadedTranscriptionModel = nil
    Memory.clearCache()

    let speakerPreparationTask: Task<Void, Error>? = if executionPolicy.keepsAuxiliaryModelsResident {
      Task { try await speakerPipeline.prepareModels { _ in } }
    } else {
      nil
    }

    let cache = HubCache(cacheDirectory: Self.modelRootURL)
    let client = HubClient(cache: cache)
    switch requestedModel {
    case .parakeetUnifiedEN:
      // FluidAudio's lowest-latency Unified tier: 160 ms of audio plus
      // 160 ms of right context, while retaining punctuation and capitalization.
      let manager = StreamingUnifiedAsrManager(
        config: UnifiedConfig(leftFrames: 70, chunkFrames: 2, rightFrames: 2),
        encoderPrecision: .int8
      )
      try await manager.loadModels(progressHandler: { progress in
        Task { @MainActor in
          progressHandler(progress.fractionCompleted)
        }
      })
      parakeetModel = manager

    case .qwen3ASR:
      let modelDirectory = try await ModelUtils.resolveOrDownloadModel(
        client: client,
        cache: cache,
        repoID: repository,
        requiredExtension: "safetensors",
        progressHandler: { progress in
          progressHandler(progress.fractionCompleted)
        }
      )
      qwenModel = try await Qwen3ASRModel.fromModelDirectory(modelDirectory)

    case .whisperLargeV3Turbo:
      let modelDirectory = try await ModelUtils.resolveOrDownloadModel(
        client: client,
        cache: cache,
        repoID: repository,
        requiredExtension: "safetensors",
        additionalMatchingPatterns: ["*.json", "*.txt", "*.model", "merges.txt", "vocab.json"],
        progressHandler: { progress in
          progressHandler(progress.fractionCompleted * 0.9)
        }
      )
      let transcriptionModel = try await WhisperModel.fromDirectory(
        modelDirectory,
        cache: cache
      )
      guard let vadRepository = Repo.ID(rawValue: Self.sileroModelID) else {
        throw MacTranscriptionError.invalidModelIdentifier
      }
      let vadDirectory = try await ModelUtils.resolveOrDownloadModel(
        client: client,
        cache: cache,
        repoID: vadRepository,
        requiredExtension: "safetensors",
        progressHandler: { progress in
          progressHandler(0.9 + progress.fractionCompleted * 0.1)
        }
      )
      whisperModels = try MacWhisperModelBundle(
        transcriptionModel: transcriptionModel,
        vadModel: SileroVAD.fromModelDirectory(vadDirectory)
      )
    }

    try await speakerPreparationTask?.value
    loadedTranscriptionModel = requestedModel
    await progressHandler(1)
  }

  func speakerEnrollmentEmbedding(from fileURL: URL) async throws -> [Float] {
    let result = try await speakerPipeline.diarize(fileURL)
    return try result.enrollmentEmbedding()
  }

  func startRecording(
    recordingURL: URL,
    audioSourceMode: MacAudioSourceMode,
    liveTranscriptionEnabled: Bool,
    speakerProfiles: [SpeakerProfile],
    eventHandler: @escaping @MainActor @Sendable (MacTranscriptionEvent) -> Void
  ) async throws {
    if liveTranscriptionEnabled, loadedTranscriptionModel == nil {
      throw MacTranscriptionError.modelNotLoaded
    }
    guard audioEngine == nil, systemAudioCapture == nil, audioMixer == nil else { return }
    self.eventHandler = eventHandler
    streamingAudioBuffer.reset()
    streamingTranscriptState.reset()
    confirmedTranscriptTimeline.reset()
    checkpointState.reset()
    isParakeetSessionActive = false
    isWhisperSessionActive = false

    guard let outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: Self.sampleRate,
      channels: 1,
      interleaved: false
    ) else {
      throw MacTranscriptionError.audioConversionFailed
    }
    let audioFile = try AVAudioFile(forWriting: recordingURL, settings: outputFormat.settings)

    let parakeetSession: StreamingUnifiedAsrManager?
    if let parakeetModel, liveTranscriptionEnabled {
      try await parakeetModel.reset()
      parakeetSession = parakeetModel
    } else {
      parakeetSession = nil
    }
    isParakeetSessionActive = parakeetSession != nil

    let session: StreamingInferenceSession? = if let qwenModel, liveTranscriptionEnabled {
      StreamingInferenceSession(
        model: qwenModel,
        config: StreamingConfig(
          decodeIntervalSeconds: 2,
          boundaryDecodeIntervalSeconds: 0.5,
          delayPreset: .subtitle,
          language: "English",
          maxTokensPerPass: 1024,
          maxDecodeWindows: 2,
          finalizeCompletedWindows: true
        )
      )
    } else {
      nil
    }

    let transcriptionFailureHandler: @Sendable (String) -> Void = { [weak self] message in
      Task {
        await self?.handleCaptureFailure(message)
      }
    }

    if let parakeetSession {
      feedTask = Self.makeParakeetTranscriptionTask(
        audioBuffer: streamingAudioBuffer,
        manager: parakeetSession,
        transcriptState: streamingTranscriptState,
        transcriptTimeline: confirmedTranscriptTimeline,
        eventHandler: eventHandler,
        failureHandler: transcriptionFailureHandler
      )
    } else if let session {
      let transcriptState = streamingTranscriptState
      let transcriptTimeline = confirmedTranscriptTimeline
      let audioBuffer = streamingAudioBuffer
      eventTask = Task {
        for await event in session.events {
          switch event {
          case let .provisional(text):
            let displayText = transcriptState.updateProvisional(
              QwenStreamingTextCleaner.clean(text)
            )
            await eventHandler(.text(displayText))
          case let .confirmed(text):
            let confirmedText = QwenStreamingTextCleaner.clean(text)
            let displayText = transcriptState.updateConfirmed(confirmedText)
            transcriptTimeline.update(
              text: confirmedText,
              audioEndTimeMS: Self.stableAudioEndTimeMS(in: audioBuffer)
            )
            await eventHandler(.text(displayText))
          case let .displayUpdate(confirmedText, provisionalText):
            let cleanedConfirmedText = QwenStreamingTextCleaner.clean(confirmedText)
            let displayText = transcriptState.update(
              confirmed: cleanedConfirmedText,
              provisional: QwenStreamingTextCleaner.clean(provisionalText)
            )
            transcriptTimeline.update(
              text: cleanedConfirmedText,
              audioEndTimeMS: Self.stableAudioEndTimeMS(in: audioBuffer)
            )
            await eventHandler(.text(displayText))
          case .stats:
            break
          case let .ended(fullText):
            transcriptState.finish(QwenStreamingTextCleaner.clean(fullText))
          }
        }
      }

      feedTask = Task.detached {
        while !Task.isCancelled {
          let samples = audioBuffer.drain()
          if !samples.isEmpty {
            session.feedAudio(samples: samples)
          }
          try? await Task.sleep(for: .milliseconds(100))
        }
      }
    } else if let whisperModels, liveTranscriptionEnabled {
      isWhisperSessionActive = true
      let phraseStream = AsyncStream<MacSpeechPhrase>.makeStream()
      eventTask = Self.makeWhisperTranscriptionTask(
        phraseStream: phraseStream.stream,
        models: whisperModels,
        transcriptState: streamingTranscriptState,
        transcriptTimeline: confirmedTranscriptTimeline,
        eventHandler: eventHandler
      )
      feedTask = Self.makeWhisperVADTask(
        audioBuffer: streamingAudioBuffer,
        models: whisperModels,
        continuation: phraseStream.continuation,
        failureHandler: transcriptionFailureHandler
      )
    }

    let audioBuffer = streamingAudioBuffer
    let recordingMeter = MacRecordingMeter()
    let consumer = MacMixedAudioConsumer(
      audioFile: audioFile,
      format: outputFormat,
      recordingMeter: recordingMeter,
      streamingAudioBuffer: audioBuffer,
      keepsTranscriptionAudio: isParakeetSessionActive || session != nil || isWhisperSessionActive,
      eventHandler: eventHandler,
      failureHandler: transcriptionFailureHandler
    )
    let mixer = MacRealtimeAudioMixer()

    do {
      if audioSourceMode.includesMeetingAudio {
        let capture = MacSystemAudioCapture()
        systemAudioCapture = capture
        try await capture.start(
          chunkHandler: { chunk in
            mixer.append(chunk)
          },
          failureHandler: transcriptionFailureHandler
        )
      }

      if audioSourceMode.includesMicrophone {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
          throw MacTranscriptionError.invalidMicrophoneFormat
        }

        inputNode.installTap(
          onBus: 0,
          bufferSize: 1600,
          format: inputFormat
        ) { inputBuffer, _ in
          do {
            let converted = try Self.resampleBuffer(inputBuffer, with: converter)
            let samples = Self.samples(from: converted)
            let duration = Double(samples.count) / Self.sampleRate
            mixer.append(MacCapturedAudioChunk(
              source: .microphone,
              samples: samples,
              startUptime: ProcessInfo.processInfo.systemUptime - duration
            ))
          } catch {
            transcriptionFailureHandler(error.localizedDescription)
          }
        }
        engine.prepare()
        try engine.start()
        audioEngine = engine
      }
    } catch {
      if let audioEngine {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()
      }
      audioEngine = nil
      await systemAudioCapture?.stop()
      systemAudioCapture = nil
      mixer.stop()
      feedTask?.cancel()
      _ = await feedTask?.value
      feedTask = nil
      session?.stop()
      _ = await eventTask?.value
      eventTask = nil
      self.eventHandler = nil
      isParakeetSessionActive = false
      isWhisperSessionActive = false
      confirmedTranscriptTimeline.reset()
      checkpointState.reset()
      throw error
    }

    mixer.start { samples in
      consumer.consume(samples)
    }

    self.session = session
    audioMixer = mixer
    mixedAudioConsumer = consumer
    self.recordingURL = recordingURL
    if isParakeetSessionActive || session != nil || isWhisperSessionActive {
      checkpointTask = Self.makeCheckpointTask(
        audioBuffer: streamingAudioBuffer,
        transcriptTimeline: confirmedTranscriptTimeline,
        checkpointState: checkpointState,
        speakerPipeline: speakerPipeline,
        speakerProfiles: speakerProfiles,
        eventHandler: eventHandler
      )
    }
  }

  func stopRecording(speakerProfiles: [SpeakerProfile]) async {
    let completedRecordingURL = recordingURL
    if let audioEngine {
      audioEngine.inputNode.removeTap(onBus: 0)
      audioEngine.stop()
      audioEngine.reset()
    }
    audioEngine = nil
    await systemAudioCapture?.stop()
    systemAudioCapture = nil
    audioMixer?.stop()
    audioMixer = nil
    mixedAudioConsumer = nil
    recordingURL = nil

    if isParakeetSessionActive || session != nil || isWhisperSessionActive {
      feedTask?.cancel()
      _ = await feedTask?.value
      feedTask = nil

      checkpointTask?.cancel()
      _ = await checkpointTask?.value
      checkpointTask = nil

      if let session {
        let finalPendingSamples = streamingAudioBuffer.drain()
        if !finalPendingSamples.isEmpty {
          session.feedAudio(samples: finalPendingSamples)
        }
        session.stop()
      }

      _ = await eventTask?.value
      eventTask = nil

      var finalText = streamingTranscriptState.resolvedText()
      let checkpoint = checkpointState.snapshot()
      var attributedText = checkpoint?.text ?? ""
      var speakerTurns = checkpoint?.speakerTurns ?? []
      var speakerEmbeddings = checkpoint?.speakerEmbeddings ?? [:]
      var speakerProfileIDs = checkpoint?.speakerProfileIDs ?? [:]
      var speakerNames = checkpoint?.speakerNames ?? [:]
      var refinementError: String?
      let allSamples = streamingAudioBuffer.snapshot()
      let output: STTOutput? = if allSamples.count >= Int(Self.sampleRate),
                                  let qwenModel {
        qwenModel.generate(
          audio: MLXArray(allSamples),
          generationParameters: STTGenerateParameters(
            maxTokens: 8192,
            language: "English",
            chunkDuration: 30,
            minChunkDuration: 1
          )
        )
      } else if allSamples.count >= Int(Self.sampleRate),
                let whisperModels {
        whisperModels.transcriptionModel.generate(
          audio: MLXArray(allSamples),
          generationParameters: Self.englishWhisperGenerationParameters(
            for: whisperModels.transcriptionModel
          )
        )
      } else {
        nil
      }
      var chunks: [MacTranscriptionChunk] = []
      if let output {
        let batchText = QwenStreamingTextCleaner.clean(output.text)
        if !batchText.isEmpty {
          finalText = batchText
        }
        chunks = Self.makeTranscriptionChunks(
          from: output,
          fallbackDuration: Double(allSamples.count) / Self.sampleRate
        )
      } else if loadedTranscriptionModel == .parakeetUnifiedEN,
                !finalText.isEmpty,
                allSamples.count >= Int(Self.sampleRate) {
        chunks = [MacTranscriptionChunk(
          text: finalText,
          startTimeMS: 0,
          endTimeMS: Int64(
            (Double(allSamples.count) / Self.sampleRate * 1000).rounded()
          ),
          language: "English"
        )]
      }
      if !chunks.isEmpty {
        do {
          guard let completedRecordingURL else {
            throw MacTranscriptionError.missingRecording
          }
          let diarization = try await speakerPipeline.diarize(completedRecordingURL)
          let turns = try await speakerPipeline.alignAndMerge(
            samples: allSamples,
            transcript: finalText,
            chunks: chunks,
            diarization: diarization.intervals
          )
          let restoredText = SpeakerAttributionCore.joinTranscript(turns.map(\.text))
          if !restoredText.isEmpty {
            finalText = restoredText
          }
          attributedText = turns.isEmpty ? "" : finalText
          speakerTurns = turns
          speakerEmbeddings = diarization.speakerEmbeddings
          let matches = SpeakerProfileMatcher.matches(
            speakerEmbeddingCandidates: diarization.speakerEmbeddingCandidates,
            profiles: speakerProfiles
          )
          speakerProfileIDs = matches.mapValues(\.profileID)
          speakerNames = matches.mapValues(\.name)
        } catch {
          refinementError = error.localizedDescription
        }
      }
      if let eventHandler {
        await eventHandler(.stopped(MacFinalTranscription(
          text: finalText,
          attributedText: attributedText,
          speakerTurns: speakerTurns,
          speakerEmbeddings: speakerEmbeddings,
          speakerProfileIDs: speakerProfileIDs,
          speakerNames: speakerNames,
          refinementError: refinementError
        )))
      }
    } else if let eventHandler {
      await eventHandler(.stopped(MacFinalTranscription(
        text: "",
        attributedText: "",
        speakerTurns: [],
        speakerEmbeddings: [:],
        speakerProfileIDs: [:],
        speakerNames: [:],
        refinementError: nil
      )))
    }
    confirmedTranscriptTimeline.reset()
    checkpointState.reset()
    session = nil
    isParakeetSessionActive = false
    isWhisperSessionActive = false
    eventHandler = nil
  }

  private func handleCaptureFailure(_ message: String) async {
    guard let eventHandler else { return }
    self.eventHandler = nil

    if let audioEngine {
      audioEngine.inputNode.removeTap(onBus: 0)
      audioEngine.stop()
      audioEngine.reset()
    }
    audioEngine = nil
    let capture = systemAudioCapture
    systemAudioCapture = nil
    await capture?.stop()
    audioMixer?.stop()
    audioMixer = nil
    mixedAudioConsumer = nil
    recordingURL = nil

    feedTask?.cancel()
    _ = await feedTask?.value
    feedTask = nil
    checkpointTask?.cancel()
    _ = await checkpointTask?.value
    checkpointTask = nil
    session?.stop()
    _ = await eventTask?.value
    eventTask = nil
    session = nil
    isParakeetSessionActive = false
    isWhisperSessionActive = false
    confirmedTranscriptTimeline.reset()
    checkpointState.reset()
    await eventHandler(.failure(message))
  }

  private nonisolated static func makeParakeetTranscriptionTask(
    audioBuffer: MacStreamingAudioBuffer,
    manager: StreamingUnifiedAsrManager,
    transcriptState: MacStreamingTranscriptState,
    transcriptTimeline: MacConfirmedTranscriptTimeline,
    eventHandler: @escaping @MainActor @Sendable (MacTranscriptionEvent) -> Void,
    failureHandler: @escaping @Sendable (String) -> Void
  ) -> Task<Void, Never> {
    Task.detached(priority: .userInitiated) {
      do {
        func process(_ samples: [Float], final: Bool) async throws -> String {
          if !samples.isEmpty {
            let buffer = try makeAudioBuffer(from: samples)
            try await manager.appendAudio(buffer)
          }
          if final {
            return try await manager.finish()
          }
          try await manager.processBufferedAudio()
          return await manager.getPartialTranscript()
        }

        while !Task.isCancelled {
          let samples = audioBuffer.drain()
          if !samples.isEmpty {
            let text = try await process(samples, final: false)
              .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
              let displayText = transcriptState.updateConfirmed(text)
              transcriptTimeline.update(
                text: text,
                audioEndTimeMS: max(
                  audioBuffer.durationMS(sampleRate: sampleRate) - 320,
                  0
                )
              )
              await eventHandler(.text(displayText))
            }
          }
          try? await Task.sleep(for: .milliseconds(50))
        }

        let finalText = try await process(audioBuffer.drain(), final: true)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptState.finish(finalText)
        if !finalText.isEmpty {
          transcriptTimeline.update(
            text: finalText,
            audioEndTimeMS: audioBuffer.durationMS(sampleRate: sampleRate)
          )
          await eventHandler(.text(finalText))
        }
      } catch {
        failureHandler("Parakeet transcription failed: \(error.localizedDescription)")
      }
    }
  }

  private nonisolated static func makeWhisperVADTask(
    audioBuffer: MacStreamingAudioBuffer,
    models: MacWhisperModelBundle,
    continuation: AsyncStream<MacSpeechPhrase>.Continuation,
    failureHandler: @escaping @Sendable (String) -> Void
  ) -> Task<Void, Never> {
    Task.detached(priority: .userInitiated) {
      let vadChunkSize = 512
      var pendingSamples: [Float] = []
      var segmenter = MacSpeechPhraseSegmenter()

      do {
        var vadState = try models.vadModel.initialState(sampleRate: Int(sampleRate))

        func processAvailableSamples(flushRemainder: Bool) throws {
          while pendingSamples.count >= vadChunkSize
            || flushRemainder && !pendingSamples.isEmpty {
            let sampleCount = min(vadChunkSize, pendingSamples.count)
            let samples = Array(pendingSamples.prefix(sampleCount))
            pendingSamples.removeFirst(sampleCount)
            let vadSamples = sampleCount == vadChunkSize
              ? samples
              : samples + Array(repeating: 0, count: vadChunkSize - sampleCount)
            let (probability, newState) = try models.vadModel.feed(
              chunk: MLXArray(vadSamples),
              state: vadState,
              sampleRate: Int(sampleRate)
            )
            vadState = newState
            eval(probability)
            let speechProbability = probability.asArray(Float.self).first ?? 0
            if let phrase = segmenter.consume(
              samples: samples,
              speechProbability: speechProbability
            ) {
              continuation.yield(phrase)
            }
          }
        }

        while !Task.isCancelled {
          let samples = audioBuffer.drain()
          if !samples.isEmpty {
            pendingSamples.append(contentsOf: samples)
            try processAvailableSamples(flushRemainder: false)
          }
          try? await Task.sleep(for: .milliseconds(32))
        }

        pendingSamples.append(contentsOf: audioBuffer.drain())
        try processAvailableSamples(flushRemainder: true)
        if let phrase = segmenter.flush() {
          continuation.yield(phrase)
        }
        continuation.finish()
      } catch {
        continuation.finish()
        failureHandler("Voice activity detection failed: \(error.localizedDescription)")
      }
    }
  }

  private nonisolated static func makeWhisperTranscriptionTask(
    phraseStream: AsyncStream<MacSpeechPhrase>,
    models: MacWhisperModelBundle,
    transcriptState: MacStreamingTranscriptState,
    transcriptTimeline: MacConfirmedTranscriptTimeline,
    eventHandler: @escaping @MainActor @Sendable (MacTranscriptionEvent) -> Void
  ) -> Task<Void, Never> {
    Task.detached(priority: .userInitiated) {
      var confirmedText = ""
      for await phrase in phraseStream {
        let output = models.transcriptionModel.generate(
          audio: MLXArray(phrase.samples),
          generationParameters: englishWhisperGenerationParameters(
            for: models.transcriptionModel
          )
        )
        let phraseText = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phraseText.isEmpty else { continue }
        confirmedText = [confirmedText, phraseText]
          .filter { !$0.isEmpty }
          .joined(separator: " ")
        let displayText = transcriptState.updateConfirmed(confirmedText)
        transcriptTimeline.update(
          text: confirmedText,
          audioEndTimeMS: Int64(
            (Double(phrase.endSample) / sampleRate * 1000).rounded()
          )
        )
        await eventHandler(.text(displayText))
      }
      transcriptState.finish(confirmedText)
    }
  }

  private nonisolated static func englishWhisperGenerationParameters(
    for model: WhisperModel
  ) -> STTGenerateParameters {
    let defaults = model.defaultGenerationParameters
    return STTGenerateParameters(
      maxTokens: defaults.maxTokens,
      temperature: defaults.temperature,
      topP: defaults.topP,
      topK: defaults.topK,
      verbose: defaults.verbose,
      language: "en",
      chunkDuration: defaults.chunkDuration,
      minChunkDuration: defaults.minChunkDuration,
      repetitionPenalty: defaults.repetitionPenalty,
      repetitionContextSize: defaults.repetitionContextSize,
      kvBits: defaults.kvBits,
      kvGroupSize: defaults.kvGroupSize,
      quantizedKVStart: defaults.quantizedKVStart
    )
  }

  private nonisolated static func makeCheckpointTask(
    audioBuffer: MacStreamingAudioBuffer,
    transcriptTimeline: MacConfirmedTranscriptTimeline,
    checkpointState: MacSpeakerCheckpointState,
    speakerPipeline: MacSpeakerPipeline,
    speakerProfiles: [SpeakerProfile],
    eventHandler: @escaping @MainActor @Sendable (MacTranscriptionEvent) -> Void
  ) -> Task<Void, Never> {
    Task.detached(priority: .utility) {
      var lastCheckpointEndTimeMS: Int64 = 0
      var lastCheckpointText = ""

      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(1))
          try Task.checkCancellation()

          switch ProcessInfo.processInfo.thermalState {
          case .critical, .serious:
            continue
          case .fair, .nominal:
            break
          @unknown default:
            continue
          }

          let transcriptSnapshot = transcriptTimeline.snapshot()
          let endTimeMS = transcriptSnapshot.endTimeMS
          let requiredAdvanceMS = checkpointAdvanceMS(at: endTimeMS)
          guard endTimeMS >= 12000,
                endTimeMS - lastCheckpointEndTimeMS >= requiredAdvanceMS,
                transcriptSnapshot.text != lastCheckpointText,
                !transcriptSnapshot.chunks.isEmpty
          else {
            continue
          }

          // Mark the attempt before starting expensive work so a failed checkpoint does
          // not retry every second. The final Stop pass still retries the complete file.
          lastCheckpointEndTimeMS = endTimeMS
          lastCheckpointText = transcriptSnapshot.text

          let availableSamples = audioBuffer.snapshot()
          let stableSampleCount = min(
            Int(Double(endTimeMS) / 1000 * sampleRate),
            availableSamples.count
          )
          guard stableSampleCount >= Int(sampleRate * 10) else { continue }
          let stableSamples = Array(availableSamples.prefix(stableSampleCount))

          let diarization = try await speakerPipeline.diarize(stableSamples)
          try Task.checkCancellation()
          let turns = try await speakerPipeline.alignAndMerge(
            samples: stableSamples,
            transcript: transcriptSnapshot.text,
            chunks: transcriptSnapshot.chunks,
            diarization: diarization.intervals
          )
          try Task.checkCancellation()
          guard !turns.isEmpty else { continue }

          let matches = SpeakerProfileMatcher.matches(
            speakerEmbeddingCandidates: diarization.speakerEmbeddingCandidates,
            profiles: speakerProfiles
          )
          let checkpoint = MacSpeakerCheckpoint(
            text: transcriptSnapshot.text,
            speakerTurns: turns,
            speakerEmbeddings: diarization.speakerEmbeddings,
            speakerProfileIDs: matches.mapValues(\.profileID),
            speakerNames: matches.mapValues(\.name)
          )
          checkpointState.update(checkpoint)
          await eventHandler(.speakerCheckpoint(checkpoint))
        } catch is CancellationError {
          break
        } catch {
          continue
        }
      }
    }
  }

  private nonisolated static func stableAudioEndTimeMS(
    in audioBuffer: MacStreamingAudioBuffer
  ) -> Int64 {
    // Confirmed Qwen text trails captured audio. Excluding the newest 1.5 seconds
    // keeps provisional speech out of the checkpoint alignment window.
    max(audioBuffer.durationMS(sampleRate: sampleRate) - 1500, 0)
  }

  private nonisolated static func checkpointAdvanceMS(at endTimeMS: Int64) -> Int64 {
    switch endTimeMS {
    case ..<60000:
      12000
    case ..<300_000:
      20000
    default:
      45000
    }
  }

  private nonisolated static func resampleBuffer(
    _ inputBuffer: AVAudioPCMBuffer,
    with converter: AVAudioConverter
  ) throws -> AVAudioPCMBuffer {
    let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
    let capacity = max(1, Int(ceil(Double(inputBuffer.frameLength) * ratio)))
    guard let outputBuffer = AVAudioPCMBuffer(
      pcmFormat: converter.outputFormat,
      frameCapacity: AVAudioFrameCount(capacity)
    ) else {
      throw MacTranscriptionError.audioConversionFailed
    }

    var suppliedInput = false
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
      if suppliedInput {
        // Each tap callback supplies one chunk, but the converter is reused for the
        // entire recording. Marking this as end-of-stream permanently drains it.
        outputStatus.pointee = .noDataNow
        return nil
      }
      suppliedInput = true
      outputStatus.pointee = .haveData
      return inputBuffer
    }
    if status == .error {
      throw conversionError ?? MacTranscriptionError.audioConversionFailed
    }
    return outputBuffer
  }

  private nonisolated static func makeAudioBuffer(
    from samples: [Float]
  ) throws -> AVAudioPCMBuffer {
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: 1,
      interleaved: false
    ),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
      ),
      let channel = buffer.floatChannelData?.pointee
    else {
      throw MacTranscriptionError.audioConversionFailed
    }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    channel.update(from: samples, count: samples.count)
    return buffer
  }

  private nonisolated static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
    guard let channel = buffer.floatChannelData?.pointee else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
  }

  private nonisolated static func makeTranscriptionChunks(
    from output: STTOutput,
    fallbackDuration: Double
  ) -> [MacTranscriptionChunk] {
    let chunks = output.segments?.compactMap { segment -> MacTranscriptionChunk? in
      guard let text = segment["text"] as? String else { return nil }
      let start = segment["start"] as? Double ?? 0
      let end = segment["end"] as? Double ?? fallbackDuration
      return MacTranscriptionChunk(
        text: text.trimmingCharacters(in: .whitespacesAndNewlines),
        startTimeMS: Int64((start * 1000).rounded()),
        endTimeMS: Int64((end * 1000).rounded()),
        language: segment["language"] as? String
      )
    } ?? []

    if !chunks.isEmpty {
      return chunks
    }
    let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return [] }
    return [MacTranscriptionChunk(
      text: text,
      startTimeMS: 0,
      endTimeMS: Int64((fallbackDuration * 1000).rounded()),
      language: output.language
    )]
  }
}

// MARK: - MacTranscriptionError

private enum MacTranscriptionError: LocalizedError {
  case invalidModelIdentifier
  case modelNotLoaded
  case microphonePermissionDenied
  case invalidMicrophoneFormat
  case audioConversionFailed
  case audioRecordingFailed
  case audioPlaybackFailed
  case missingRecording

  var errorDescription: String? {
    switch self {
    case .invalidModelIdentifier:
      "The transcription model identifier is invalid."
    case .modelNotLoaded:
      "Prepare the transcription model before recording."
    case .microphonePermissionDenied:
      "Microphone access is required. Enable it in System Settings → Privacy & Security → Microphone."
    case .invalidMicrophoneFormat:
      "The selected microphone does not provide a usable audio format."
    case .audioConversionFailed:
      "Microphone audio could not be converted to the required 16 kHz format."
    case .audioRecordingFailed:
      "The voice sample recording could not be started."
    case .audioPlaybackFailed:
      "The voice sample could not be played."
    case .missingRecording:
      "The completed recording could not be found for speaker refinement."
    }
  }
}
