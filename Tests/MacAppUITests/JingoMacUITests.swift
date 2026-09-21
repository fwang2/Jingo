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

    app.buttons["Recordings"].click()
    XCTAssertTrue(app.staticTexts["No recordings yet"].waitForExistence(timeout: 2))

    app.buttons["Settings"].click()
    XCTAssertTrue(app.staticTexts["Default model"].waitForExistence(timeout: 2))
    XCTAssertTrue(element("settings.audioSource").exists)
    XCTAssertTrue(app.staticTexts[
      "Use Mac audio and microphone for a detected Zoom or Teams meeting; otherwise use the microphone."
    ].exists)
    XCTAssertTrue(element("settings.transcriptFontSize").exists)
    XCTAssertTrue(app.staticTexts["14 pt"].exists)
    XCTAssertTrue(element("settings.automaticSummaries").exists)
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
    XCTAssertTrue(app.staticTexts["Jingo folder"].exists)
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

  func testFailedSummaryOffersModelDownload() {
    launch(scenario: "summary-failed")

    app.buttons["Recordings"].click()
    app.buttons["Show transcript"].click()

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
    app.buttons["Show transcript"].click()

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
    XCTAssertTrue(app.staticTexts["2 voice samples"].exists)
    let playSample = element("speakerProfile.play.B29365B1-5DE8-416F-B5F8-92D44834FCF8")
    XCTAssertTrue(playSample.exists)
    XCTAssertTrue(playSample.isEnabled)
    playSample.click()
    let playing = NSPredicate(format: "label == %@", "Stop voice sample")
    expectation(for: playing, evaluatedWith: playSample)
    waitForExpectations(timeout: 2)

    element("speakerProfile.manage.B29365B1-5DE8-416F-B5F8-92D44834FCF8").click()
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

  private func launch(scenario: String) {
    app = XCUIApplication()
    app.launchEnvironment["JINGO_UI_TEST_SCENARIO"] = scenario
    app.launch()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }
}
