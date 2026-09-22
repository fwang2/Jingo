import XCTest

final class JingoMacUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  override func tearDownWithError() throws {
    app?.terminate()
    app = nil
  }

  func testEmptyTranscriptCanvasAndNavigation() {
    launch(scenario: "empty")

    XCTAssertTrue(element("transcript.canvas").waitForExistence(timeout: 5))
    XCTAssertTrue(element("transcript.empty").exists)
    XCTAssertTrue(app.staticTexts["Ready when you are"].exists)
    XCTAssertTrue(app.staticTexts["Audio input: Automatic microphone selection"].exists)

    app.buttons["Recordings"].click()
    XCTAssertTrue(app.staticTexts["No recordings yet"].waitForExistence(timeout: 2))

    app.buttons["Settings"].click()
    XCTAssertTrue(app.staticTexts["Default model"].waitForExistence(timeout: 2))
    XCTAssertTrue(element("settings.audioSource").exists)
    XCTAssertTrue(app.staticTexts[
      "Use the microphone immediately. If Mac audio access was previously granted, detect Zoom or Teams and include their audio automatically."
    ].exists)
    XCTAssertTrue(element("settings.transcriptFontSize").exists)
    XCTAssertTrue(app.staticTexts["14 pt"].exists)
    XCTAssertFalse(element("settings.automaticSummaries").exists)
    XCTAssertTrue(app.staticTexts["On-device"].exists)
    XCTAssertTrue(app.staticTexts["Qwen3 4B · 4-bit"].exists)
    XCTAssertTrue(element("settings.prepareSummaryModel").exists)
    XCTAssertTrue(element("settings.summaryInstructions").exists)
    XCTAssertTrue(element("settings.summaryInstructionsTabs").exists)
    XCTAssertTrue(element("settings.summaryInstructions.editTab").exists)
    XCTAssertTrue(element("settings.summaryInstructions.previewTab").exists)
    XCTAssertFalse(element("settings.summaryInstructionsPreview").exists)
    element("settings.summaryInstructions.previewTab").click()
    XCTAssertTrue(element("settings.summaryInstructionsPreview").exists)

    app.buttons["Backup & Restore"].click()
    XCTAssertTrue(element("account.recordingBackup").waitForExistence(timeout: 2))
    XCTAssertTrue(element("account.syncFolderStatus").exists)
    XCTAssertTrue(element("account.chooseSyncFolder").exists)
    XCTAssertTrue(element("account.syncSettings").exists)
    XCTAssertTrue(element("account.backUpNow").exists)
    XCTAssertTrue(element("account.recordingBackupStatus").exists)
    XCTAssertTrue(element("account.automaticRecordingBackup").exists)
    XCTAssertTrue(element("account.automaticRecordingBackupStatus").exists)
    XCTAssertTrue(element("account.recordingRestore").exists)
    XCTAssertTrue(element("account.refreshBackups").exists)
    XCTAssertTrue(element("account.restoreAll").exists)
    XCTAssertTrue(element("account.syncFolderConnected").exists)
    XCTAssertTrue(app.staticTexts["Connected"].exists)
    XCTAssertTrue(app.staticTexts["Settings sync automatically through the chosen cloud-synced shared folder."].exists)
    XCTAssertTrue(app.staticTexts["Automatic backup is off by default. Local recordings are never removed or changed."].exists)

    app.buttons["Known Speakers"].click()
    XCTAssertTrue(element("speakerProfiles.title").waitForExistence(timeout: 2))

    app.buttons["Live Transcript"].click()
    XCTAssertTrue(element("transcript.empty").waitForExistence(timeout: 2))
  }

  func testLiveTranscriptUsesUnifiedCanvas() {
    launch(scenario: "live")

    XCTAssertTrue(element("transcript.canvas").waitForExistence(timeout: 5))
    let liveText = element("transcript.liveText")
    XCTAssertTrue(liveText.exists)
    XCTAssertTrue(liveText.label.contains("same canvas"))
    XCTAssertFalse(element("speakerTurn.0").exists)
    XCTAssertTrue(app.staticTexts["00:09"].exists)
    XCTAssertTrue(element("recording.waveform").exists)
    XCTAssertTrue(app.buttons["Stop"].exists)
    XCTAssertTrue(app.staticTexts["Audio input: Logitech Webcam C930e"].exists)
  }

  func testCheckpointShowsStableSpeakerTurnsAndLiveTail() {
    launch(scenario: "checkpoint")

    XCTAssertTrue(element("transcript.canvas").waitForExistence(timeout: 5))
    XCTAssertFalse(element("transcript.liveText").exists)
    XCTAssertEqual(element("speaker.speaker-1").label, "Speaker 1")
    XCTAssertEqual(element("speaker.speaker-2").label, "Speaker 2")
    XCTAssertEqual(element("speakerTurn.text.0").label, "Welcome to the review.")
    XCTAssertTrue(element("speakerTurn.text.1").label.contains("separates the speakers"))
    XCTAssertTrue(element("transcript.liveTail").label.contains("still being transcribed"))
    XCTAssertTrue(app.buttons["Stop"].exists)
    XCTAssertTrue(app.staticTexts[
      "Audio input: Mac audio + Logitech Webcam C930e"
    ].exists)
  }

  func testStoppedRecordingKeepsSpeakerTurnsTimestampsAndFinalTail() {
    launch(scenario: "stopped-checkpoint-tail")

    XCTAssertFalse(element("transcript.liveText").exists)
    XCTAssertTrue(element("speaker.speaker-1").label.contains("Feiyi"))
    XCTAssertEqual(element("speakerTurn.timestamp.0").label, "00:01 – 00:05")
    XCTAssertEqual(element("speakerTurn.text.0").label, "Welcome to the review.")
    XCTAssertEqual(
      element("transcript.liveTail").label,
      "This final sentence arrived while stopping."
    )
    XCTAssertFalse(app.buttons["Stop"].exists)
  }

  func testSingleSpeakerFinalTranscriptAndRename() {
    launch(scenario: "single-speaker")

    XCTAssertTrue(element("transcript.canvas").waitForExistence(timeout: 5))
    XCTAssertFalse(element("transcript.liveText").exists)
    XCTAssertEqual(element("speakerTurn.timestamp.0").label, "00:01 – 00:09")
    XCTAssertTrue(element("speakerTurn.text.0").label.contains("remains in place"))

    let speakerButton = element("speaker.speaker-1")
    XCTAssertTrue(speakerButton.exists)
    XCTAssertTrue(speakerButton.label.contains("Feiyi"))
    speakerButton.click()

    // SwiftUI's macOS alert hosts its text field outside the labeled content tree.
    let renameField = app.textFields.firstMatch
    XCTAssertTrue(renameField.waitForExistence(timeout: 2))
    renameField.click()
    renameField.typeKey("a", modifierFlags: .command)
    renameField.typeText("Jordan")
    let renameSheet = app.sheets.firstMatch
    XCTAssertTrue(renameSheet.waitForExistence(timeout: 2))
    renameSheet.buttons["Save"].click()

    let renamedSpeaker = element("speaker.speaker-1")
    let renamed = NSPredicate(format: "label CONTAINS %@", "Jordan")
    expectation(for: renamed, evaluatedWith: renamedSpeaker)
    waitForExpectations(timeout: 2)
  }

  func testMultipleSpeakerTranscriptShowsEveryTurn() {
    launch(scenario: "multiple-speakers")

    XCTAssertTrue(element("transcript.canvas").waitForExistence(timeout: 5))
    XCTAssertTrue(element("speaker.speaker-1").label.contains("Feiyi"))
    XCTAssertTrue(element("speaker.speaker-2").label.contains("Guest"))
    XCTAssertEqual(element("speakerTurn.timestamp.0").label, "00:00 – 00:04")
    XCTAssertEqual(element("speakerTurn.timestamp.1").label, "00:04 – 00:10")
    XCTAssertEqual(element("speakerTurn.text.0").label, "Welcome to the review.")
    XCTAssertTrue(element("speakerTurn.text.1").label.contains("transcript canvas"))
  }

  func testRecordingActionsOfferOfflineReplacementWithoutLiveRestore() {
    launch(scenario: "offline-refined")

    app.buttons["Recordings"].click()
    let actions = element(
      "recording.actions.3C476724-2F61-4630-A237-411F9B460A76"
    )
    XCTAssertTrue(actions.waitForExistence(timeout: 2))
    actions.click()
    XCTAssertTrue(app.menuItems["Retranscribe Offline"].exists)
    XCTAssertFalse(app.menuItems["Restore Live Transcript"].exists)
  }

  func testTranscriptLinkOpensTranscriptTabBesideRecordings() {
    launch(scenario: "offline-refined")

    app.buttons["Recordings"].click()
    openInstalledRecordingTranscript()
    XCTAssertTrue(
      element("recording.transcriptText")
        .waitForExistence(timeout: 2)
    )
    XCTAssertTrue(element("recordings.tabs").exists)
    XCTAssertTrue(app.staticTexts["Transcript"].exists)
  }

  func testManualSpeakerNameSurvivesPersistenceAndDiarizationIDChanges() {
    launch(scenario: "manual-speaker-override")

    app.buttons["Recordings"].click()
    openInstalledRecordingTranscript()
    XCTAssertTrue(element("speaker.cluster-b").waitForExistence(timeout: 2))
    XCTAssertTrue(element("speaker.cluster-b").label.contains("Jordan"))
  }

  func testSpeakerTurnPlaybackStartsAtTurnTimestamp() {
    launch(scenario: "manual-speaker-override")

    app.buttons["Recordings"].click()
    openInstalledRecordingTranscript()

    let playback = element("speakerTurn.playback.0")
    XCTAssertTrue(playback.waitForExistence(timeout: 2))
    XCTAssertTrue(element("speakerTurn.playback.1").exists)
    XCTAssertEqual(playback.label, "Play from 00:01")
    playback.click()

    let playing = NSPredicate(format: "label == %@", "Stop playback from 00:01")
    expectation(for: playing, evaluatedWith: playback)
    waitForExpectations(timeout: 2)
  }

  func testRecordingPlaybackCanBeStoppedAndRecordingCanMoveToTrash() {
    launch(scenario: "offline-refined")

    app.buttons["Recordings"].click()
    let recordingID = "3C476724-2F61-4630-A237-411F9B460A76"
    let playback = element("recording.playback.\(recordingID)")
    XCTAssertTrue(playback.waitForExistence(timeout: 2))
    XCTAssertEqual(playback.label, "Play recording")

    playback.click()
    let playing = NSPredicate(format: "label == %@", "Stop recording")
    expectation(for: playing, evaluatedWith: playback)
    waitForExpectations(timeout: 2)

    playback.click()
    let stopped = NSPredicate(format: "label == %@", "Play recording")
    expectation(for: stopped, evaluatedWith: playback)
    waitForExpectations(timeout: 2)

    let trash = element("recording.trash.\(recordingID)")
    XCTAssertTrue(trash.exists)
    trash.click()
    XCTAssertTrue(app.buttons["Move to Trash"].waitForExistence(timeout: 2))
    app.sheets.buttons["Cancel"].click()
  }

  func testMultipleRecordingsCanBeSelectedAndMovedToTrash() {
    launch(scenario: "multiple-recordings")

    app.buttons["Recordings"].click()
    let firstID = "3C476724-2F61-4630-A237-411F9B460A76"
    let secondID = "5A4D17F4-9F8F-47EF-836B-E181A6A98F01"
    let remainingID = "B1A70D4C-6B86-454C-8577-3506572C17B4"
    XCTAssertTrue(element("recording.playback.\(firstID)").waitForExistence(timeout: 2))

    element("recordings.selectMode").click()
    element("recordings.selectAll").click()
    element("recording.selection.\(remainingID)").click()
    element("recordings.batchTrash").click()

    let confirm = app.sheets.buttons["Move 2 Recordings to Trash"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 2))
    confirm.click()

    XCTAssertFalse(element("recording.playback.\(firstID)").exists)
    XCTAssertFalse(element("recording.playback.\(secondID)").exists)
    XCTAssertTrue(element("recording.playback.\(remainingID)").exists)
    XCTAssertTrue(app.staticTexts["1 recording saved locally"].exists)
  }

  func testFailedSummaryOffersModelDownload() {
    launch(scenario: "summary-failed")

    app.buttons["Recordings"].click()
    openInstalledRecordingTranscript()

    XCTAssertTrue(app.staticTexts["Summary unavailable"].waitForExistence(timeout: 2))
    XCTAssertTrue(element("recording.prepareSummaryModel").exists)
    XCTAssertTrue(app.buttons["Try Again"].exists)
  }

  func testCustomSummaryInstructionsRenderMarkdownPreview() {
    launch(scenario: "settings-markdown")

    app.buttons["Settings"].click()
    XCTAssertEqual(
      element("settings.summaryInstructions").value as? String,
      "**Focus on decisions**"
    )
    element("settings.summaryInstructions.previewTab").click()
    XCTAssertTrue(app.staticTexts["Focus on decisions"].waitForExistence(timeout: 2))
  }

  func testDefaultSummaryPromptIsPopulatedAndPreviewable() {
    launch(scenario: "settings-default-prompt")

    app.buttons["Settings"].click()
    let prompt = element("settings.summaryInstructions").value as? String
    XCTAssertTrue(prompt?.contains("# Meeting Transcript Summary Prompt") == true)
    XCTAssertTrue(prompt?.contains("## Not Decided / Still Open") == true)

    element("settings.summaryInstructions.previewTab").click()
    XCTAssertTrue(app.staticTexts["Meeting Transcript Summary Prompt"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["Not Decided / Still Open"].exists)
  }

  func testCompletedSummaryRendersMarkdownWithoutShowingSyntax() {
    launch(scenario: "summary-markdown")

    app.buttons["Recordings"].click()
    openInstalledRecordingTranscript()

    XCTAssertEqual(
      element("summary.overview").label,
      "The launch plan was approved with a local review."
    )
    XCTAssertEqual(element("summary.keyPoint.0").label, "•, Review the release plan.")
    XCTAssertEqual(element("summary.decision.0").label, "•, Ship the approved plan.")
    XCTAssertEqual(element("summary.openItem.0").label, "•, The launch date remains open.")
    XCTAssertEqual(
      element("summary.participantContribution.0").label,
      "•, Feiyi proposed the final review."
    )
    XCTAssertEqual(element("summary.actionItem.0").label, "Publish the final plan.")
    XCTAssertEqual(
      element("summary.riskOrQuestion.0").label,
      "•, Confirm whether the reviewer is available."
    )
    XCTAssertEqual(element("summary.highlight.0").label, "Approval recorded.")
    XCTAssertEqual(
      element("summary.meetingStatus").label,
      "The group reached a decision and moved to execution."
    )
  }

  func testKnownSpeakerManagementAndManualEnrollmentEntry() {
    launch(scenario: "speaker-management")

    app.buttons["Known Speakers"].click()
    XCTAssertTrue(element("speakerProfiles.title").waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["Feiyi"].exists)
    XCTAssertFalse(app.staticTexts["2 voice samples"].exists)
    let playSample = element("speakerProfile.play.B29365B1-5DE8-416F-B5F8-92D44834FCF8")
    XCTAssertTrue(playSample.exists)
    XCTAssertTrue(playSample.isEnabled)
    playSample.click()
    let playing = NSPredicate(format: "label == %@", "Stop voice sample")
    expectation(for: playing, evaluatedWith: playSample)
    waitForExpectations(timeout: 2)

    let profileID = "B29365B1-5DE8-416F-B5F8-92D44834FCF8"
    let speakerName = element("speakerProfile.name.\(profileID)")
    XCTAssertTrue(speakerName.exists)
    speakerName.doubleClick()
    let renameField = element("speakerProfile.renameField.\(profileID)")
    XCTAssertTrue(renameField.waitForExistence(timeout: 2))
    renameField.typeKey("a", modifierFlags: .command)
    renameField.typeText("Jordan")
    element("speakerProfiles.title").click()
    XCTAssertTrue(app.staticTexts["Jordan"].waitForExistence(timeout: 2))

    element("speakerProfile.manage.\(profileID)").click()
    app.menuItems["Add Voice Sample"].click()
    let addVoiceSampleButton = element("speakerEnrollment.record")
    XCTAssertTrue(addVoiceSampleButton.waitForExistence(timeout: 2))
    XCTAssertTrue(addVoiceSampleButton.isEnabled)
    app.buttons["Cancel"].click()

    element("speakerProfiles.add").click()
    XCTAssertTrue(app.staticTexts["Add Speaker"].waitForExistence(timeout: 2))
    XCTAssertTrue(element("speakerEnrollment.name").exists)
    XCTAssertTrue(element("speakerEnrollment.record").exists)
    XCTAssertTrue(app.staticTexts["Record 10 seconds"].exists)
    XCTAssertTrue(
      app.staticTexts["The sample saves automatically after 10 seconds of detected speech."].exists
    )
  }

  func testDeveloperBenchmarkRunsManually() {
    launch(scenario: "manual-speaker-override")

    app.buttons["Developer"].click()
    let runButton = element("developer.benchmark.run")
    XCTAssertTrue(runButton.waitForExistence(timeout: 2))
    runButton.click()

    XCTAssertTrue(element("developer.benchmark.results").waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["Latest result"].exists)
  }

  private func launch(scenario: String) {
    app = XCUIApplication()
    app.launchEnvironment["JINGO_UI_TEST_SCENARIO"] = scenario
    app.launchEnvironment["JINGO_UI_TEST_WINDOWED"] = "1"
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
  }

  private func openInstalledRecordingTranscript() {
    element("recording.transcript.3C476724-2F61-4630-A237-411F9B460A76").click()
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }
}
