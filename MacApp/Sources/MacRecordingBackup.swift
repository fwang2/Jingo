import CryptoKit
import Foundation

// MARK: - MacRecordingBackupSource

struct MacRecordingBackupSource: Sendable {
  let id: UUID
  let createdAt: Date
  let displayName: String
  let originalAudioFileName: String
  let metadata: Data
  let audioURL: URL
}

// MARK: - MacRecordingBackupManifest

struct MacRecordingBackupManifest: Codable, Equatable, Sendable {
  static let formatIdentifier = "com.jingo.recording-backup"
  static let currentSchemaVersion = 1

  struct FileEntry: Codable, Equatable, Sendable {
    let fileName: String
    let byteCount: Int64
    let sha256: String
  }

  let formatIdentifier: String
  let schemaVersion: Int
  let recordingID: UUID
  let createdAt: Date
  let exportedAt: Date
  let originalAudioFileName: String
  let metadata: FileEntry
  let audio: FileEntry
}

// MARK: - MacRecordingBackupProgress

struct MacRecordingBackupProgress: Equatable, Sendable {
  let completedCount: Int
  let totalCount: Int
  let currentRecordingName: String

  var fractionCompleted: Double {
    guard totalCount > 0 else {
      return 1
    }
    return Double(completedCount) / Double(totalCount)
  }
}

// MARK: - MacRecordingBackupReport

struct MacRecordingBackupReport: Equatable, Sendable {
  struct Failure: Equatable, Sendable {
    let recordingID: UUID
    let recordingName: String
    let message: String
  }

  var uploadedCount = 0
  var skippedCount = 0
  var failures: [Failure] = []
}

// MARK: - MacRecordingBackupStoring

protocol MacRecordingBackupStoring: Sendable {
  func backUp(
    _ sources: [MacRecordingBackupSource],
    progress: @escaping @Sendable (MacRecordingBackupProgress) async -> Void
  ) async throws -> MacRecordingBackupReport
  func loadBackups() async throws -> MacRecordingBackupCatalog
  func prepareRestore(recordingID: UUID) async throws -> MacRecordingRestorePreparation
  func restoreAudio(
    from preparation: MacRecordingRestorePreparation,
    to destinationURL: URL
  ) async throws
}

// MARK: - MacRecordingBackupStore

actor MacRecordingBackupStore: MacRecordingBackupStoring {
  private enum BackupResult {
    case uploaded
    case skipped
  }

  let fileManager: FileManager
  private let folderURLProvider: @Sendable () -> URL?

  init(
    fileManager: FileManager = .default,
    folderURLProvider: @escaping @Sendable () -> URL?
  ) {
    self.fileManager = fileManager
    self.folderURLProvider = folderURLProvider
  }

  func backUp(
    _ sources: [MacRecordingBackupSource],
    progress: @escaping @Sendable (MacRecordingBackupProgress) async -> Void
  ) async throws -> MacRecordingBackupReport {
    let recordingsDirectory = try recordingsDirectory()
    var report = MacRecordingBackupReport()

    for (index, source) in sources.enumerated() {
      try Task.checkCancellation()
      await progress(.init(
        completedCount: index,
        totalCount: sources.count,
        currentRecordingName: source.displayName
      ))

      do {
        switch try await backUp(source, in: recordingsDirectory) {
        case .uploaded:
          report.uploadedCount += 1

        case .skipped:
          report.skippedCount += 1
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        report.failures.append(.init(
          recordingID: source.id,
          recordingName: source.displayName,
          message: error.localizedDescription
        ))
      }

      await progress(.init(
        completedCount: index + 1,
        totalCount: sources.count,
        currentRecordingName: source.displayName
      ))
    }

    return report
  }

  private func backUp(
    _ source: MacRecordingBackupSource,
    in recordingsDirectory: URL
  ) async throws -> BackupResult {
    guard fileManager.fileExists(atPath: source.audioURL.path) else {
      throw MacRecordingBackupError.audioFileMissing(source.originalAudioFileName)
    }

    let metadataEntry = MacRecordingBackupManifest.FileEntry(
      fileName: "metadata.json",
      byteCount: Int64(source.metadata.count),
      sha256: Self.sha256(source.metadata)
    )
    let audioHash = try Self.sha256(fileAt: source.audioURL)
    let audioFileName = Self.backupAudioFileName(for: source.originalAudioFileName)
    let audioEntry = MacRecordingBackupManifest.FileEntry(
      fileName: audioFileName,
      byteCount: audioHash.byteCount,
      sha256: audioHash.sha256
    )
    let packageURL = recordingsDirectory
      .appendingPathComponent(source.id.uuidString, isDirectory: true)
    let manifestURL = packageURL.appendingPathComponent("manifest.json")

    if let existingManifest = try await loadManifestIfPresent(from: manifestURL) {
      guard existingManifest.formatIdentifier == MacRecordingBackupManifest.formatIdentifier else {
        throw MacRecordingBackupError.unrecognizedBackupFormat
      }
      guard existingManifest.schemaVersion <= MacRecordingBackupManifest.currentSchemaVersion else {
        throw MacRecordingBackupError.unsupportedSchema(existingManifest.schemaVersion)
      }

      let metadataURL = packageURL.appendingPathComponent(existingManifest.metadata.fileName)
      let audioURL = packageURL.appendingPathComponent(existingManifest.audio.fileName)
      if existingManifest.recordingID == source.id,
         existingManifest.metadata == metadataEntry,
         existingManifest.audio == audioEntry,
         fileManager.fileExists(atPath: metadataURL.path),
         fileManager.fileExists(atPath: audioURL.path) {
        return .skipped
      }
    }

    let manifest = MacRecordingBackupManifest(
      formatIdentifier: MacRecordingBackupManifest.formatIdentifier,
      schemaVersion: MacRecordingBackupManifest.currentSchemaVersion,
      recordingID: source.id,
      createdAt: source.createdAt,
      exportedAt: Date(),
      originalAudioFileName: source.originalAudioFileName,
      metadata: metadataEntry,
      audio: audioEntry
    )
    let manifestData = try MacRecordingBackupJSON.encode(manifest)

    try writePackage(
      source: source,
      metadataEntry: metadataEntry,
      audioEntry: audioEntry,
      manifestData: manifestData,
      to: packageURL
    )

    return .uploaded
  }

  private func writePackage(
    source: MacRecordingBackupSource,
    metadataEntry: MacRecordingBackupManifest.FileEntry,
    audioEntry: MacRecordingBackupManifest.FileEntry,
    manifestData: Data,
    to packageURL: URL
  ) throws {
    try coordinatedWrite(to: packageURL) { coordinatedPackageURL in
      try fileManager.createDirectory(
        at: coordinatedPackageURL,
        withIntermediateDirectories: true
      )
      try writeReplacing(
        source.metadata,
        at: coordinatedPackageURL.appendingPathComponent(metadataEntry.fileName)
      )
      try copyReplacing(
        source.audioURL,
        at: coordinatedPackageURL.appendingPathComponent(audioEntry.fileName)
      )
      // The manifest is written last so an interrupted upload never advertises
      // a package whose files have not finished updating.
      try writeReplacing(
        manifestData,
        at: coordinatedPackageURL.appendingPathComponent("manifest.json")
      )
    }
  }

  func recordingsDirectory() throws -> URL {
    guard let folderURL = folderURLProvider() else {
      throw MacRecordingBackupError.folderUnavailable
    }
    return folderURL
      .appendingPathComponent("Recordings", isDirectory: true)
      .appendingPathComponent("v1", isDirectory: true)
  }

  func loadManifestIfPresent(
    from manifestURL: URL
  ) async throws -> MacRecordingBackupManifest? {
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      return nil
    }
    try await downloadIfNeeded(at: manifestURL)
    let data = try coordinatedRead(from: manifestURL)
    do {
      return try MacRecordingBackupJSON.decode(MacRecordingBackupManifest.self, from: data)
    } catch {
      throw MacRecordingBackupError.invalidManifest
    }
  }

  func coordinatedRead(from url: URL) throws -> Data {
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var result: Result<Data, Error>?
    coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
      result = Result { try Data(contentsOf: coordinatedURL) }
    }
    if let coordinationError {
      throw coordinationError
    }
    guard let result else {
      throw MacRecordingBackupError.readFailed
    }
    return try result.get()
  }

  private func coordinatedWrite(
    to packageURL: URL,
    operation: (URL) throws -> Void
  ) throws {
    let coordinator = NSFileCoordinator()
    var coordinationError: NSError?
    var writeError: Error?
    coordinator.coordinate(writingItemAt: packageURL, options: [], error: &coordinationError) { coordinatedURL in
      do {
        try operation(coordinatedURL)
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

  private func writeReplacing(_ data: Data, at destinationURL: URL) throws {
    let stagedURL = destinationURL.deletingLastPathComponent()
      .appendingPathComponent(".\(UUID().uuidString).tmp")
    defer { try? fileManager.removeItem(at: stagedURL) }
    try data.write(to: stagedURL, options: .atomic)
    try replaceOrMove(stagedURL, to: destinationURL)
  }

  private func copyReplacing(_ sourceURL: URL, at destinationURL: URL) throws {
    let stagedURL = destinationURL.deletingLastPathComponent()
      .appendingPathComponent(".\(UUID().uuidString).tmp")
    defer { try? fileManager.removeItem(at: stagedURL) }
    try fileManager.copyItem(at: sourceURL, to: stagedURL)
    try replaceOrMove(stagedURL, to: destinationURL)
  }

  private func replaceOrMove(_ sourceURL: URL, to destinationURL: URL) throws {
    if fileManager.fileExists(atPath: destinationURL.path) {
      _ = try fileManager.replaceItemAt(destinationURL, withItemAt: sourceURL)
    } else {
      try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }
  }

  func waitForDownloadIfNeeded(at url: URL) async throws {
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
    throw MacRecordingBackupError.downloadTimedOut
  }

  private static func backupAudioFileName(for originalFileName: String) -> String {
    let pathExtension = URL(fileURLWithPath: originalFileName).pathExtension.lowercased()
    return pathExtension.isEmpty ? "audio.bin" : "audio.\(pathExtension)"
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func sha256(fileAt url: URL) throws -> (sha256: String, byteCount: Int64) {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hasher = SHA256()
    var byteCount: Int64 = 0
    while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
      try Task.checkCancellation()
      byteCount += Int64(data.count)
      hasher.update(data: data)
    }
    return (
      hasher.finalize().map { String(format: "%02x", $0) }.joined(),
      byteCount
    )
  }
}

// MARK: - MacRecordingBackupJSON

enum MacRecordingBackupJSON {
  static func encode(_ value: some Encodable) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    try JSONDecoder().decode(type, from: data)
  }
}

// MARK: - MacRecordingBackupError

enum MacRecordingBackupError: LocalizedError {
  case audioDestinationExists
  case audioFileMissing(String)
  case backupChanged
  case backupFileMissing(String)
  case checksumMismatch(String)
  case folderUnavailable
  case downloadTimedOut
  case invalidManifest
  case manifestMissing
  case readFailed
  case recordingIDMismatch
  case recordingMetadataMismatch
  case unsafeFileName
  case unrecognizedBackupFormat
  case unsupportedSchema(Int)

  var errorDescription: String? {
    switch self {
    case .audioDestinationExists:
      "A local audio file already exists at the restore destination. Nothing was overwritten."

    case let .audioFileMissing(fileName):
      "The local audio file \(fileName) is missing."

    case .backupChanged:
      "The recording backup changed while it was being restored. Please try again."

    case let .backupFileMissing(fileName):
      "The backup file \(fileName) is missing."

    case let .checksumMismatch(fileName):
      "The backup file \(fileName) failed its integrity check."

    case .folderUnavailable:
      "Jingo could not access the selected sync folder."

    case .downloadTimedOut:
      "A synchronized recording manifest did not finish downloading in time."

    case .invalidManifest:
      "An existing recording backup has an invalid manifest."

    case .manifestMissing:
      "The recording backup manifest is missing."

    case .readFailed:
      "Jingo could not read an existing recording backup."

    case .recordingIDMismatch:
      "The recording backup identifier does not match its package."

    case .recordingMetadataMismatch:
      "The recording metadata does not match its backup manifest."

    case .unsafeFileName:
      "The recording backup contains an unsafe file name."

    case .unrecognizedBackupFormat:
      "An existing recording backup uses an unrecognized format."

    case let .unsupportedSchema(version):
      "The recording backup was created by a newer Jingo version (schema \(version))."
    }
  }
}
