import Foundation

// MARK: - MacCloudSetting

struct MacCloudSetting<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
  var value: Value
  var modifiedAt: Date
  var deviceID: String

  func merged(with other: Self) -> Self {
    if modifiedAt != other.modifiedAt {
      return modifiedAt > other.modifiedAt ? self : other
    }
    return deviceID >= other.deviceID ? self : other
  }
}

// MARK: - MacCloudSettings

struct MacCloudSettings: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 2

  var schemaVersion = currentSchemaVersion
  var liveTranscriptionEnabled: MacCloudSetting<Bool>
  var transcriptFontSize: MacCloudSetting<Double>
  var automaticSummariesEnabled: MacCloudSetting<Bool>
  var customSummaryInstructions: MacCloudSetting<String>
  var automaticRecordingBackupEnabled: MacCloudSetting<Bool>

  init(
    schemaVersion: Int = currentSchemaVersion,
    liveTranscriptionEnabled: MacCloudSetting<Bool>,
    transcriptFontSize: MacCloudSetting<Double>,
    automaticSummariesEnabled: MacCloudSetting<Bool>,
    customSummaryInstructions: MacCloudSetting<String>,
    automaticRecordingBackupEnabled: MacCloudSetting<Bool>
  ) {
    self.schemaVersion = schemaVersion
    self.liveTranscriptionEnabled = liveTranscriptionEnabled
    self.transcriptFontSize = transcriptFontSize
    self.automaticSummariesEnabled = automaticSummariesEnabled
    self.customSummaryInstructions = customSummaryInstructions
    self.automaticRecordingBackupEnabled = automaticRecordingBackupEnabled
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    liveTranscriptionEnabled = try container.decode(
      MacCloudSetting<Bool>.self,
      forKey: .liveTranscriptionEnabled
    )
    transcriptFontSize = try container.decode(
      MacCloudSetting<Double>.self,
      forKey: .transcriptFontSize
    )
    automaticSummariesEnabled = try container.decode(
      MacCloudSetting<Bool>.self,
      forKey: .automaticSummariesEnabled
    )
    customSummaryInstructions = try container.decode(
      MacCloudSetting<String>.self,
      forKey: .customSummaryInstructions
    )
    automaticRecordingBackupEnabled = try container.decodeIfPresent(
      MacCloudSetting<Bool>.self,
      forKey: .automaticRecordingBackupEnabled
    ) ?? .init(value: false, modifiedAt: .distantPast, deviceID: "legacy")
  }

  static func legacy(
    liveTranscriptionEnabled: Bool,
    transcriptFontSize: Double,
    automaticSummariesEnabled: Bool,
    customSummaryInstructions: String,
    automaticRecordingBackupEnabled: Bool,
    deviceID: String
  ) -> Self {
    let legacyDate = Date.distantPast
    return Self(
      liveTranscriptionEnabled: .init(
        value: liveTranscriptionEnabled,
        modifiedAt: legacyDate,
        deviceID: deviceID
      ),
      transcriptFontSize: .init(
        value: transcriptFontSize,
        modifiedAt: legacyDate,
        deviceID: deviceID
      ),
      automaticSummariesEnabled: .init(
        value: automaticSummariesEnabled,
        modifiedAt: legacyDate,
        deviceID: deviceID
      ),
      customSummaryInstructions: .init(
        value: customSummaryInstructions,
        modifiedAt: legacyDate,
        deviceID: deviceID
      ),
      automaticRecordingBackupEnabled: .init(
        value: automaticRecordingBackupEnabled,
        modifiedAt: legacyDate,
        deviceID: deviceID
      )
    )
  }

  func updating(
    liveTranscriptionEnabled: Bool,
    transcriptFontSize: Double,
    automaticSummariesEnabled: Bool,
    customSummaryInstructions: String,
    automaticRecordingBackupEnabled: Bool,
    modifiedAt: Date,
    deviceID: String
  ) -> Self {
    var updated = self
    if updated.liveTranscriptionEnabled.value != liveTranscriptionEnabled {
      updated.liveTranscriptionEnabled = .init(
        value: liveTranscriptionEnabled,
        modifiedAt: modifiedAt,
        deviceID: deviceID
      )
    }
    if updated.transcriptFontSize.value != transcriptFontSize {
      updated.transcriptFontSize = .init(
        value: transcriptFontSize,
        modifiedAt: modifiedAt,
        deviceID: deviceID
      )
    }
    if updated.automaticSummariesEnabled.value != automaticSummariesEnabled {
      updated.automaticSummariesEnabled = .init(
        value: automaticSummariesEnabled,
        modifiedAt: modifiedAt,
        deviceID: deviceID
      )
    }
    if updated.customSummaryInstructions.value != customSummaryInstructions {
      updated.customSummaryInstructions = .init(
        value: customSummaryInstructions,
        modifiedAt: modifiedAt,
        deviceID: deviceID
      )
    }
    if updated.automaticRecordingBackupEnabled.value != automaticRecordingBackupEnabled {
      updated.automaticRecordingBackupEnabled = .init(
        value: automaticRecordingBackupEnabled,
        modifiedAt: modifiedAt,
        deviceID: deviceID
      )
    }
    return updated
  }

  func merged(with other: Self) -> Self {
    Self(
      schemaVersion: max(schemaVersion, other.schemaVersion),
      liveTranscriptionEnabled: liveTranscriptionEnabled.merged(
        with: other.liveTranscriptionEnabled
      ),
      transcriptFontSize: transcriptFontSize.merged(with: other.transcriptFontSize),
      automaticSummariesEnabled: automaticSummariesEnabled.merged(
        with: other.automaticSummariesEnabled
      ),
      customSummaryInstructions: customSummaryInstructions.merged(
        with: other.customSummaryInstructions
      ),
      automaticRecordingBackupEnabled: automaticRecordingBackupEnabled.merged(
        with: other.automaticRecordingBackupEnabled
      )
    )
  }
}

// MARK: - MacSyncSettingsStoring

protocol MacSyncSettingsStoring: Sendable {
  func folderStatus() async -> MacSyncFolderStatus
  func loadSettings() async throws -> MacCloudSettings?
  func saveSettings(_ settings: MacCloudSettings) async throws
}

// MARK: - MacSyncSettingsStore

actor MacSyncSettingsStore: MacSyncSettingsStoring {
  private let fileManager: FileManager
  private let folderURLProvider: @Sendable () -> URL?

  init(
    fileManager: FileManager = .default,
    folderURLProvider: @escaping @Sendable () -> URL?
  ) {
    self.fileManager = fileManager
    self.folderURLProvider = folderURLProvider
  }

  func folderStatus() -> MacSyncFolderStatus {
    guard let url = folderURLProvider() else {
      return .notConfigured
    }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else {
      return .unavailable("The selected folder is not available. Reconnect its drive or choose another folder.")
    }
    return .available(url)
  }

  func loadSettings() async throws -> MacCloudSettings? {
    let settingsURL = try settingsURL()
    guard fileManager.fileExists(atPath: settingsURL.path) else {
      return nil
    }

    if fileManager.isUbiquitousItem(at: settingsURL) {
      try fileManager.startDownloadingUbiquitousItem(at: settingsURL)
      try await waitForDownloadIfNeeded(at: settingsURL)
    }

    let data = try coordinatedRead(from: settingsURL)
    let settings = try JSONDecoder().decode(MacCloudSettings.self, from: data)
    guard settings.schemaVersion <= MacCloudSettings.currentSchemaVersion else {
      throw MacSyncSettingsError.unsupportedSchema(settings.schemaVersion)
    }
    return settings
  }

  func saveSettings(_ settings: MacCloudSettings) throws {
    let settingsURL = try settingsURL()
    let directoryURL = settingsURL.deletingLastPathComponent()
    let data = try JSONEncoder().encode(settings)
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var writeError: Error?

    coordinator.coordinate(
      writingItemAt: directoryURL,
      options: [],
      error: &coordinationError
    ) { coordinatedDirectoryURL in
      do {
        try fileManager.createDirectory(
          at: coordinatedDirectoryURL,
          withIntermediateDirectories: true
        )
        try data.write(
          to: coordinatedDirectoryURL.appendingPathComponent(settingsURL.lastPathComponent),
          options: .atomic
        )
      } catch {
        writeError = error
      }
    }

    if let coordinationError {
      throw coordinationError
    }
    if let writeError {
      throw writeError
    }
  }

  private func settingsURL() throws -> URL {
    guard let folderURL = folderURLProvider() else {
      throw MacSyncSettingsError.folderUnavailable
    }
    return folderURL
      .appendingPathComponent("Settings", isDirectory: true)
      .appendingPathComponent("settings-v1.json")
  }

  private func coordinatedRead(from url: URL) throws -> Data {
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var readResult: Result<Data, Error>?

    coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
      readResult = Result { try Data(contentsOf: coordinatedURL) }
    }

    if let coordinationError {
      throw coordinationError
    }
    guard let readResult else {
      throw MacSyncSettingsError.readFailed
    }
    return try readResult.get()
  }

  private func waitForDownloadIfNeeded(at url: URL) async throws {
    for _ in 0 ..< 100 {
      try Task.checkCancellation()
      let values = try url.resourceValues(forKeys: [
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemDownloadingErrorKey,
      ])
      if let error = values.ubiquitousItemDownloadingError {
        throw error
      }
      if values.ubiquitousItemDownloadingStatus != .notDownloaded {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw MacSyncSettingsError.downloadTimedOut
  }
}

// MARK: - MacSyncSettingsError

enum MacSyncSettingsError: LocalizedError {
  case folderUnavailable
  case downloadTimedOut
  case readFailed
  case unsupportedSchema(Int)

  var errorDescription: String? {
    switch self {
    case .folderUnavailable:
      "Jingo could not access the selected sync folder."

    case .downloadTimedOut:
      "The synchronized settings download did not finish in time."

    case .readFailed:
      "Jingo could not read the synchronized settings file."

    case let .unsupportedSchema(version):
      "The synchronized settings were created by a newer Jingo version (schema \(version))."
    }
  }
}
