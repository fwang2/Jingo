import Foundation
import XCTest

// This target intentionally has no CustomDump dependency.
// swiftlint:disable xctassertnodifference_preferred
final class MacRecordingBackupTests: XCTestCase {
  func testFirstBackupCreatesVersionedPackage() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = MacRecordingBackupStore(folderURLProvider: { fixture.directory })

    let report = try await store.backUp([fixture.source]) { _ in }

    XCTAssertEqual(report.uploadedCount, 1)
    XCTAssertEqual(report.skippedCount, 0)
    XCTAssertTrue(report.failures.isEmpty)

    let packageURL = packageURL(for: fixture.source.id, in: fixture.directory)
    let manifestData = try Data(contentsOf: packageURL.appendingPathComponent("manifest.json"))
    let manifest = try MacRecordingBackupJSON.decode(
      MacRecordingBackupManifest.self,
      from: manifestData
    )
    XCTAssertEqual(manifest.formatIdentifier, MacRecordingBackupManifest.formatIdentifier)
    XCTAssertEqual(manifest.schemaVersion, MacRecordingBackupManifest.currentSchemaVersion)
    XCTAssertEqual(manifest.recordingID, fixture.source.id)
    XCTAssertEqual(manifest.metadata.fileName, "metadata.json")
    XCTAssertEqual(manifest.metadata.byteCount, Int64(fixture.source.metadata.count))
    XCTAssertEqual(manifest.audio.fileName, "audio.caf")
    XCTAssertEqual(manifest.audio.byteCount, 12)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: packageURL.appendingPathComponent(manifest.metadata.fileName).path
      )
    )
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: packageURL.appendingPathComponent(manifest.audio.fileName).path
      )
    )
  }

  func testUnchangedBackupIsSkipped() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = MacRecordingBackupStore(folderURLProvider: { fixture.directory })

    let firstReport = try await store.backUp([fixture.source]) { _ in }
    let secondReport = try await store.backUp([fixture.source]) { _ in }

    XCTAssertEqual(firstReport.uploadedCount, 1)
    XCTAssertEqual(secondReport.uploadedCount, 0)
    XCTAssertEqual(secondReport.skippedCount, 1)
    XCTAssertTrue(secondReport.failures.isEmpty)
  }

  func testChangedMetadataUpdatesBackupWithoutChangingLocalFiles() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = MacRecordingBackupStore(folderURLProvider: { fixture.directory })
    _ = try await store.backUp([fixture.source]) { _ in }

    let changedMetadata = Data(#"{"transcript":"updated"}"#.utf8)
    let changedSource = MacRecordingBackupSource(
      id: fixture.source.id,
      createdAt: fixture.source.createdAt,
      displayName: fixture.source.displayName,
      originalAudioFileName: fixture.source.originalAudioFileName,
      metadata: changedMetadata,
      audioURL: fixture.source.audioURL
    )
    let report = try await store.backUp([changedSource]) { _ in }

    XCTAssertEqual(report.uploadedCount, 1)
    XCTAssertEqual(try Data(contentsOf: fixture.source.audioURL), Data("sample-audio".utf8))
    XCTAssertEqual(
      try Data(contentsOf: packageURL(for: fixture.source.id, in: fixture.directory)
        .appendingPathComponent("metadata.json")),
      changedMetadata
    )
  }

  func testMissingAudioIsReportedWithoutStoppingOtherBackups() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let missingID = UUID()
    let missingSource = MacRecordingBackupSource(
      id: missingID,
      createdAt: Date(timeIntervalSince1970: 50),
      displayName: "Missing recording",
      originalAudioFileName: "missing.caf",
      metadata: Data(#"{"transcript":"missing"}"#.utf8),
      audioURL: fixture.directory.appendingPathComponent("missing.caf")
    )
    let store = MacRecordingBackupStore(folderURLProvider: { fixture.directory })

    let report = try await store.backUp([missingSource, fixture.source]) { _ in }

    XCTAssertEqual(report.uploadedCount, 1)
    XCTAssertEqual(report.failures.count, 1)
    XCTAssertEqual(report.failures.first?.recordingID, missingID)
    XCTAssertEqual(report.failures.first?.message.contains("missing.caf"), true)
  }

  func testCatalogAndRestoreRoundTripVerifiedFiles() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = MacRecordingBackupStore(folderURLProvider: { fixture.directory })
    _ = try await store.backUp([fixture.source]) { _ in }

    let catalog = try await store.loadBackups()
    let item = try XCTUnwrap(catalog.items.first)
    let preparation = try await store.prepareRestore(recordingID: item.recordingID)
    let restoredURL = fixture.directory
      .appendingPathComponent("Restored", isDirectory: true)
      .appendingPathComponent("restored.caf")
    try await store.restoreAudio(from: preparation, to: restoredURL)

    XCTAssertTrue(catalog.failures.isEmpty)
    XCTAssertEqual(catalog.items.count, 1)
    XCTAssertEqual(preparation.metadata, fixture.source.metadata)
    XCTAssertEqual(try Data(contentsOf: restoredURL), Data("sample-audio".utf8))
  }

  func testRestoreRejectsCorruptMetadata() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = MacRecordingBackupStore(folderURLProvider: { fixture.directory })
    _ = try await store.backUp([fixture.source]) { _ in }
    let metadataURL = packageURL(for: fixture.source.id, in: fixture.directory)
      .appendingPathComponent("metadata.json")
    try Data("corrupt".utf8).write(to: metadataURL, options: .atomic)

    do {
      _ = try await store.prepareRestore(recordingID: fixture.source.id)
      XCTFail("Expected corrupt metadata to fail validation")
    } catch {
      XCTAssertEqual(error.localizedDescription, "The backup file metadata.json failed its integrity check.")
    }
  }

  func testRestoreRejectsCorruptAudioWithoutCreatingDestination() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = MacRecordingBackupStore(folderURLProvider: { fixture.directory })
    _ = try await store.backUp([fixture.source]) { _ in }
    let preparation = try await store.prepareRestore(recordingID: fixture.source.id)
    let packageAudioURL = packageURL(for: fixture.source.id, in: fixture.directory)
      .appendingPathComponent("audio.caf")
    try Data("corrupt".utf8).write(to: packageAudioURL, options: .atomic)
    let restoredURL = fixture.directory
      .appendingPathComponent("Restored", isDirectory: true)
      .appendingPathComponent("restored.caf")

    do {
      try await store.restoreAudio(from: preparation, to: restoredURL)
      XCTFail("Expected corrupt audio to fail validation")
    } catch {
      XCTAssertEqual(error.localizedDescription, "The backup file audio.caf failed its integrity check.")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: restoredURL.path))
  }

  func testRestoreNeverOverwritesExistingAudio() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = MacRecordingBackupStore(folderURLProvider: { fixture.directory })
    _ = try await store.backUp([fixture.source]) { _ in }
    let preparation = try await store.prepareRestore(recordingID: fixture.source.id)
    let restoredDirectory = fixture.directory.appendingPathComponent("Restored", isDirectory: true)
    try FileManager.default.createDirectory(at: restoredDirectory, withIntermediateDirectories: true)
    let restoredURL = restoredDirectory.appendingPathComponent("restored.caf")
    let existingData = Data("keep-existing".utf8)
    try existingData.write(to: restoredURL)

    do {
      try await store.restoreAudio(from: preparation, to: restoredURL)
      XCTFail("Expected the destination collision to prevent restore")
    } catch {
      XCTAssertEqual(
        error.localizedDescription,
        "A local audio file already exists at the restore destination. Nothing was overwritten."
      )
    }
    XCTAssertEqual(try Data(contentsOf: restoredURL), existingData)
  }

  private func makeFixture() throws -> (
    directory: URL,
    source: MacRecordingBackupSource
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Jingo-Recording-Backup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let id = UUID()
    let audioURL = directory.appendingPathComponent("local-\(id.uuidString).caf")
    try Data("sample-audio".utf8).write(to: audioURL)
    return (
      directory,
      MacRecordingBackupSource(
        id: id,
        createdAt: Date(timeIntervalSince1970: 100),
        displayName: "Test recording",
        originalAudioFileName: "\(id.uuidString).caf",
        metadata: Data(#"{"transcript":"original"}"#.utf8),
        audioURL: audioURL
      )
    )
  }

  private func packageURL(for id: UUID, in containerURL: URL) -> URL {
    containerURL
      .appendingPathComponent("Recordings", isDirectory: true)
      .appendingPathComponent("v1", isDirectory: true)
      .appendingPathComponent(id.uuidString, isDirectory: true)
  }
}

// swiftlint:enable xctassertnodifference_preferred
