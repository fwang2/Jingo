import Foundation
import XCTest

// This target intentionally has no CustomDump dependency.
// swiftlint:disable xctassertnodifference_preferred
final class MacSyncSettingsTests: XCTestCase {
  func testMergeKeepsNewestValueForEachSetting() {
    let olderDate = Date(timeIntervalSince1970: 100)
    let newerDate = Date(timeIntervalSince1970: 200)
    let local = settings(
      liveTranscription: (false, newerDate, "local"),
      fontSize: (14, olderDate, "local"),
      automaticSummaries: (true, olderDate, "local"),
      instructions: ("Local", newerDate, "local"),
      automaticBackup: (false, olderDate, "local")
    )
    let remote = settings(
      liveTranscription: (true, olderDate, "remote"),
      fontSize: (18, newerDate, "remote"),
      automaticSummaries: (false, newerDate, "remote"),
      instructions: ("Remote", olderDate, "remote"),
      automaticBackup: (true, newerDate, "remote")
    )

    let merged = local.merged(with: remote)

    XCTAssertFalse(merged.liveTranscriptionEnabled.value)
    XCTAssertEqual(merged.transcriptFontSize.value, 18)
    XCTAssertFalse(merged.automaticSummariesEnabled.value)
    XCTAssertEqual(merged.customSummaryInstructions.value, "Local")
    XCTAssertTrue(merged.automaticRecordingBackupEnabled.value)
  }

  func testMergeUsesDeviceIDAsStableTieBreaker() {
    let date = Date(timeIntervalSince1970: 100)
    let first = MacCloudSetting(value: "First", modifiedAt: date, deviceID: "A")
    let second = MacCloudSetting(value: "Second", modifiedAt: date, deviceID: "B")

    XCTAssertEqual(first.merged(with: second).value, "Second")
    XCTAssertEqual(second.merged(with: first).value, "Second")
  }

  func testUpdatingOnlyChangesModifiedFields() {
    let originalDate = Date(timeIntervalSince1970: 100)
    let updateDate = Date(timeIntervalSince1970: 200)
    let original = settings(
      liveTranscription: (true, originalDate, "device"),
      fontSize: (14, originalDate, "device"),
      automaticSummaries: (true, originalDate, "device"),
      instructions: ("Original", originalDate, "device")
    )

    let updated = original.updating(
      liveTranscriptionEnabled: true,
      transcriptFontSize: 16,
      automaticSummariesEnabled: true,
      customSummaryInstructions: "Original",
      automaticRecordingBackupEnabled: true,
      modifiedAt: updateDate,
      deviceID: "device"
    )

    XCTAssertEqual(updated.liveTranscriptionEnabled.modifiedAt, originalDate)
    XCTAssertEqual(updated.transcriptFontSize.modifiedAt, updateDate)
    XCTAssertEqual(updated.automaticSummariesEnabled.modifiedAt, originalDate)
    XCTAssertEqual(updated.customSummaryInstructions.modifiedAt, originalDate)
    XCTAssertEqual(updated.automaticRecordingBackupEnabled.modifiedAt, updateDate)
  }

  func testStoreRoundTripsSettingsInSelectedFolder() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Jingo-Sync-Settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let store = MacSyncSettingsStore(folderURLProvider: { temporaryDirectory })
    let expected = settings(
      liveTranscription: (true, Date(timeIntervalSince1970: 100), "device"),
      fontSize: (17, Date(timeIntervalSince1970: 100), "device"),
      automaticSummaries: (false, Date(timeIntervalSince1970: 100), "device"),
      instructions: ("Focus on decisions", Date(timeIntervalSince1970: 100), "device")
    )

    let folderStatus = await store.folderStatus()
    XCTAssertEqual(folderStatus, .available(temporaryDirectory))
    try await store.saveSettings(expected)
    let actual = try await store.loadSettings()

    XCTAssertEqual(actual, expected)
  }

  func testStoreReportsMissingFolderSelection() async {
    let store = MacSyncSettingsStore(folderURLProvider: { nil })

    let folderStatus = await store.folderStatus()
    XCTAssertEqual(folderStatus, .notConfigured)
  }

  func testFolderSelectionPersistsAsSecurityScopedBookmark() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("Jingo-Sync-Bookmark-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let suiteName = "Jingo-Sync-Folder-Tests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let access = MacSyncFolderAccess(defaults: defaults)
    try access.remember(directory)
    let restoredAccess = MacSyncFolderAccess(defaults: defaults)
    let expectedURL = directory.resolvingSymlinksInPath().standardizedFileURL
    let restoredURL = restoredAccess.selectedFolderURL()?.resolvingSymlinksInPath()
      .standardizedFileURL

    XCTAssertEqual(restoredURL, expectedURL)
    guard case let .available(statusURL) = restoredAccess.status() else {
      XCTFail("Expected the remembered sync folder to remain available")
      return
    }
    XCTAssertEqual(statusURL.resolvingSymlinksInPath().standardizedFileURL, expectedURL)
  }

  func testUsingCloudLocationCreatesAndRemembersJingoFolder() throws {
    let location = FileManager.default.temporaryDirectory
      .appendingPathComponent("Jingo-Sync-Location-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: location) }

    let suiteName = "Jingo-Sync-Location-Tests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let access = MacSyncFolderAccess(defaults: defaults)
    let selectedFolder = try access.useLocation(location)
    let expectedFolder = location.appendingPathComponent("Jingo", isDirectory: true)

    XCTAssertEqual(selectedFolder, expectedFolder)
    XCTAssertEqual(access.selectedFolderURL(), expectedFolder)
    XCTAssertTrue(FileManager.default.fileExists(atPath: expectedFolder.path))
  }

  func testUsingExistingJingoFolderDoesNotCreateNestedFolder() throws {
    let jingoFolder = FileManager.default.temporaryDirectory
      .appendingPathComponent("Jingo-Sync-Existing-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("Jingo", isDirectory: true)
    try FileManager.default.createDirectory(at: jingoFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: jingoFolder.deletingLastPathComponent()) }

    let suiteName = "Jingo-Sync-Existing-Tests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let access = MacSyncFolderAccess(defaults: defaults)
    let selectedFolder = try access.useLocation(jingoFolder)

    XCTAssertEqual(selectedFolder, jingoFolder)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: jingoFolder.appendingPathComponent("Jingo", isDirectory: true).path
      )
    )
  }

  func testVersionOneSettingsDecodeWithAutomaticBackupDisabled() throws {
    let original = settings(
      liveTranscription: (true, Date(timeIntervalSince1970: 100), "device"),
      fontSize: (14, Date(timeIntervalSince1970: 100), "device"),
      automaticSummaries: (true, Date(timeIntervalSince1970: 100), "device"),
      instructions: ("Original", Date(timeIntervalSince1970: 100), "device")
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
    )
    object["schemaVersion"] = 1
    object.removeValue(forKey: "automaticRecordingBackupEnabled")

    let decoded = try JSONDecoder().decode(
      MacCloudSettings.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertFalse(decoded.automaticRecordingBackupEnabled.value)
    XCTAssertEqual(decoded.automaticRecordingBackupEnabled.deviceID, "legacy")
  }

  private func settings(
    liveTranscription: (Bool, Date, String),
    fontSize: (Double, Date, String),
    automaticSummaries: (Bool, Date, String),
    instructions: (String, Date, String),
    automaticBackup: (Bool, Date, String) = (false, .distantPast, "legacy")
  ) -> MacCloudSettings {
    MacCloudSettings(
      liveTranscriptionEnabled: .init(
        value: liveTranscription.0,
        modifiedAt: liveTranscription.1,
        deviceID: liveTranscription.2
      ),
      transcriptFontSize: .init(
        value: fontSize.0,
        modifiedAt: fontSize.1,
        deviceID: fontSize.2
      ),
      automaticSummariesEnabled: .init(
        value: automaticSummaries.0,
        modifiedAt: automaticSummaries.1,
        deviceID: automaticSummaries.2
      ),
      customSummaryInstructions: .init(
        value: instructions.0,
        modifiedAt: instructions.1,
        deviceID: instructions.2
      ),
      automaticRecordingBackupEnabled: .init(
        value: automaticBackup.0,
        modifiedAt: automaticBackup.1,
        deviceID: automaticBackup.2
      )
    )
  }
}

// swiftlint:enable xctassertnodifference_preferred
