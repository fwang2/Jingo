import Foundation

// MARK: - MacRecordingBackupCatalog

struct MacRecordingBackupCatalog: Equatable, Sendable {
  struct Failure: Equatable, Sendable {
    let packageName: String
    let message: String
  }

  var items: [MacRecordingBackupItem] = []
  var failures: [Failure] = []
}

// MARK: - MacRecordingBackupItem

struct MacRecordingBackupItem: Equatable, Identifiable, Sendable {
  var id: UUID {
    recordingID
  }

  let recordingID: UUID
  let createdAt: Date
  let exportedAt: Date
  let originalAudioFileName: String
  let audioByteCount: Int64
}

// MARK: - MacRecordingRestorePreparation

struct MacRecordingRestorePreparation: Sendable {
  let item: MacRecordingBackupItem
  let metadata: Data
  let manifest: MacRecordingBackupManifest
}

// MARK: - MacRecordingBackupStore Restore

extension MacRecordingBackupStore {
  func loadBackups() async throws -> MacRecordingBackupCatalog {
    let directory = try recordingsDirectory()
    guard fileManager.fileExists(atPath: directory.path) else {
      return MacRecordingBackupCatalog()
    }

    let packageURLs = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )
    var catalog = MacRecordingBackupCatalog()
    for packageURL in packageURLs {
      try Task.checkCancellation()
      do {
        let values = try packageURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true,
              let packageID = UUID(uuidString: packageURL.lastPathComponent)
        else {
          continue
        }
        guard let manifest = try await loadManifestIfPresent(
          from: packageURL.appendingPathComponent("manifest.json")
        ) else {
          throw MacRecordingBackupError.manifestMissing
        }
        try validate(manifest, expectedRecordingID: packageID)
        catalog.items.append(Self.item(from: manifest))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        catalog.failures.append(.init(
          packageName: packageURL.lastPathComponent,
          message: error.localizedDescription
        ))
      }
    }
    catalog.items.sort {
      if $0.createdAt != $1.createdAt {
        return $0.createdAt > $1.createdAt
      }
      return $0.recordingID.uuidString < $1.recordingID.uuidString
    }
    return catalog
  }

  func prepareRestore(recordingID: UUID) async throws -> MacRecordingRestorePreparation {
    let packageURL = try recordingsDirectory()
      .appendingPathComponent(recordingID.uuidString, isDirectory: true)
    guard let manifest = try await loadManifestIfPresent(
      from: packageURL.appendingPathComponent("manifest.json")
    ) else {
      throw MacRecordingBackupError.manifestMissing
    }
    try validate(manifest, expectedRecordingID: recordingID)

    let metadataURL = try packageFileURL(
      named: manifest.metadata.fileName,
      in: packageURL
    )
    try await downloadIfNeeded(at: metadataURL)
    let metadata = try coordinatedRead(from: metadataURL)
    try Self.validate(metadata, against: manifest.metadata)
    return MacRecordingRestorePreparation(
      item: Self.item(from: manifest),
      metadata: metadata,
      manifest: manifest
    )
  }

  func restoreAudio(
    from preparation: MacRecordingRestorePreparation,
    to destinationURL: URL
  ) async throws {
    let packageURL = try recordingsDirectory()
      .appendingPathComponent(preparation.item.recordingID.uuidString, isDirectory: true)
    guard let currentManifest = try await loadManifestIfPresent(
      from: packageURL.appendingPathComponent("manifest.json")
    ) else {
      throw MacRecordingBackupError.manifestMissing
    }
    guard currentManifest == preparation.manifest else {
      throw MacRecordingBackupError.backupChanged
    }
    try validate(currentManifest, expectedRecordingID: preparation.item.recordingID)

    let audioURL = try packageFileURL(
      named: currentManifest.audio.fileName,
      in: packageURL
    )
    try await downloadIfNeeded(at: audioURL)
    try copyRestoredAudio(
      from: audioURL,
      to: destinationURL,
      expectedEntry: currentManifest.audio
    )
  }

  private func validate(
    _ manifest: MacRecordingBackupManifest,
    expectedRecordingID: UUID
  ) throws {
    guard manifest.formatIdentifier == MacRecordingBackupManifest.formatIdentifier else {
      throw MacRecordingBackupError.unrecognizedBackupFormat
    }
    guard manifest.schemaVersion <= MacRecordingBackupManifest.currentSchemaVersion else {
      throw MacRecordingBackupError.unsupportedSchema(manifest.schemaVersion)
    }
    guard manifest.recordingID == expectedRecordingID else {
      throw MacRecordingBackupError.recordingIDMismatch
    }
    _ = try packageFileName(manifest.metadata.fileName)
    _ = try packageFileName(manifest.audio.fileName)
  }

  private func packageFileURL(named fileName: String, in packageURL: URL) throws -> URL {
    let safeFileName = try packageFileName(fileName)
    return packageURL.appendingPathComponent(safeFileName)
  }

  private func packageFileName(_ fileName: String) throws -> String {
    guard !fileName.isEmpty,
          fileName != ".",
          fileName != "..",
          URL(fileURLWithPath: fileName).lastPathComponent == fileName
    else {
      throw MacRecordingBackupError.unsafeFileName
    }
    return fileName
  }

  private func copyRestoredAudio(
    from sourceURL: URL,
    to destinationURL: URL,
    expectedEntry: MacRecordingBackupManifest.FileEntry
  ) throws {
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw MacRecordingBackupError.audioDestinationExists
    }
    try fileManager.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let stagedURL = destinationURL.deletingLastPathComponent()
      .appendingPathComponent(".restore-\(UUID().uuidString).tmp")
    defer { try? fileManager.removeItem(at: stagedURL) }

    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var copyError: Error?
    coordinator.coordinate(readingItemAt: sourceURL, options: [], error: &coordinationError) { coordinatedURL in
      do {
        try fileManager.copyItem(at: coordinatedURL, to: stagedURL)
        let hash = try Self.sha256(fileAt: stagedURL)
        guard hash.byteCount == expectedEntry.byteCount,
              hash.sha256 == expectedEntry.sha256
        else {
          throw MacRecordingBackupError.checksumMismatch(expectedEntry.fileName)
        }
        try fileManager.moveItem(at: stagedURL, to: destinationURL)
      } catch {
        copyError = error
      }
    }
    if let coordinationError {
      throw coordinationError
    }
    if let copyError {
      throw copyError
    }
  }

  func downloadIfNeeded(at url: URL) async throws {
    guard fileManager.fileExists(atPath: url.path) else {
      throw MacRecordingBackupError.backupFileMissing(url.lastPathComponent)
    }
    guard fileManager.isUbiquitousItem(at: url) else {
      return
    }
    try fileManager.startDownloadingUbiquitousItem(at: url)
    try await waitForDownloadIfNeeded(at: url)
  }

  private static func validate(
    _ data: Data,
    against entry: MacRecordingBackupManifest.FileEntry
  ) throws {
    guard Int64(data.count) == entry.byteCount,
          sha256(data) == entry.sha256
    else {
      throw MacRecordingBackupError.checksumMismatch(entry.fileName)
    }
  }

  private static func item(from manifest: MacRecordingBackupManifest) -> MacRecordingBackupItem {
    MacRecordingBackupItem(
      recordingID: manifest.recordingID,
      createdAt: manifest.createdAt,
      exportedAt: manifest.exportedAt,
      originalAudioFileName: manifest.originalAudioFileName,
      audioByteCount: manifest.audio.byteCount
    )
  }
}
