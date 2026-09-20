@testable import Common
import MeetingSummaryCore
import XCTest

final class RecordingInfoTests: XCTestCase {
  func testCompletedTranscriptionWithTextIsTranscribed() {
    let recording = makeRecording(transcriptionText: "Hello world")

    XCTAssertTrue(recording.isTranscribed)
  }

  func testCompletedTranscriptionWithoutTextCanBeTranscribedAgain() {
    let recording = makeRecording(transcriptionText: "  \n")

    XCTAssertFalse(recording.isTranscribed)
  }

  func testSpeakerNamesRoundTripWithRecording() throws {
    var recording = makeRecording(transcriptionText: "Hello world")
    recording.speakerNames = ["speaker-0": "Alice"]

    let decoded = try JSONDecoder().decode(
      RecordingInfo.self,
      from: JSONEncoder().encode(recording)
    )

    XCTAssertEqual(decoded.speakerNames, ["speaker-0": "Alice"])
  }

  func testOlderRecordingWithoutSpeakerNamesDefaultsToEmpty() throws {
    let recording = makeRecording(transcriptionText: "Hello world")
    let data = try JSONEncoder().encode(recording)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "speakerNames")

    let decoded = try JSONDecoder().decode(
      RecordingInfo.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertEqual(decoded.speakerNames, [:])
  }

  func testMeetingSummaryRoundTripsWithRecording() throws {
    var recording = makeRecording(transcriptionText: "We approved the launch plan.")
    recording.summary = MeetingSummary(
      status: .completed,
      overview: "The team approved the launch plan.",
      keyPoints: ["Launch planning"],
      decisions: ["The launch plan was approved."],
      openItems: ["The exact launch date remains open."],
      participantContributions: ["Alice proposed publishing the plan."],
      actionItems: [
        .init(task: "Publish the plan", owner: "Alice", sourceTurnIDs: ["T2"]),
      ],
      risksAndFollowUpQuestions: ["Confirm reviewer availability."],
      highlights: [
        .init(text: "Plan approval", sourceTurnIDs: ["T2"]),
      ],
      meetingStatus: "The team reached a decision and moved to execution.",
      generatedAt: Date(timeIntervalSince1970: 2),
      model: "local-model",
      sourceFingerprint: "abc"
    )

    let decoded = try JSONDecoder().decode(
      RecordingInfo.self,
      from: JSONEncoder().encode(recording)
    )

    XCTAssertEqual(decoded.summary, recording.summary)
  }

  func testOlderMeetingSummaryDefaultsNewSectionsToEmpty() throws {
    var recording = makeRecording(transcriptionText: "We approved the launch plan.")
    recording.summary = MeetingSummary(
      status: .completed,
      overview: "The launch plan was approved.",
      model: "local-model",
      sourceFingerprint: "abc"
    )
    let encoded = try JSONEncoder().encode(recording)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var summary = try XCTUnwrap(object["summary"] as? [String: Any])
    summary.removeValue(forKey: "openItems")
    summary.removeValue(forKey: "participantContributions")
    summary.removeValue(forKey: "risksAndFollowUpQuestions")
    summary.removeValue(forKey: "meetingStatus")
    object["summary"] = summary

    let decoded = try JSONDecoder().decode(
      RecordingInfo.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertEqual(decoded.summary?.openItems, [])
    XCTAssertEqual(decoded.summary?.participantContributions, [])
    XCTAssertEqual(decoded.summary?.risksAndFollowUpQuestions, [])
    XCTAssertEqual(decoded.summary?.meetingStatus, "")
  }

  func testOlderRecordingWithoutMeetingSummaryDefaultsToNil() throws {
    let recording = makeRecording(transcriptionText: "Hello world")
    let data = try JSONEncoder().encode(recording)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "summary")

    let decoded = try JSONDecoder().decode(
      RecordingInfo.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertNil(decoded.summary)
  }

  func testMeetingSummaryFingerprintIsDeterministicAndSensitiveToChanges() {
    let first = MeetingSummary.fingerprint(for: "same transcript")
    let second = MeetingSummary.fingerprint(for: "same transcript")
    let changed = MeetingSummary.fingerprint(for: "different transcript")

    XCTAssertEqual(first, second)
    XCTAssertNotEqual(first, changed)
  }

  func testMeetingSummaryLengthBudgetKeepsBriefRecordingsConcise() {
    let budget = MeetingSummaryLengthBudget.calibrated(
      duration: 47,
      transcript: "The team reviewed one idea and agreed to test it next week."
    )

    XCTAssertEqual(budget.overviewWordLimit, 35)
    XCTAssertEqual(budget.keyPointLimit, 2)
    XCTAssertEqual(budget.decisionLimit, 1)
    XCTAssertEqual(budget.actionItemLimit, 1)
    XCTAssertEqual(budget.highlightLimit, 0)
    XCTAssertEqual(budget.totalDetailLimit, 3)
  }

  func testMeetingSummaryLengthBudgetAlsoAccountsForTranscriptDensity() {
    let denseTranscript = Array(repeating: "discussion", count: 400).joined(separator: " ")
    let budget = MeetingSummaryLengthBudget.calibrated(
      duration: 60,
      transcript: denseTranscript
    )

    XCTAssertEqual(budget.overviewWordLimit, 90)
    XCTAssertEqual(budget.keyPointLimit, 6)
  }

  func testBriefMeetingSummaryIsTrimmedToItsBudget() {
    let summary = MeetingSummary(
      status: .completed,
      overview: Array(repeating: "detail", count: 60).joined(separator: " "),
      keyPoints: ["One", "Two", "Three"],
      decisions: ["Decision one", "Decision two"],
      actionItems: [
        .init(task: "Action one"),
        .init(task: "Action two"),
      ],
      highlights: [.init(text: "Highlight")],
      model: "local-model",
      sourceFingerprint: "abc"
    )
    let budget = MeetingSummaryLengthBudget.calibrated(
      duration: 47,
      transcript: "A brief meeting."
    )

    let limited = summary.limited(to: budget)

    XCTAssertEqual(limited.overview.split(separator: " ").count, 35)
    XCTAssertEqual(limited.actionItems.count, 1)
    XCTAssertEqual(limited.decisions.count, 1)
    XCTAssertEqual(limited.keyPoints.count, 1)
    XCTAssertTrue(limited.highlights.isEmpty)
  }

  func testBriefMeetingSummaryPrioritizesOutcomesAcrossNewSections() {
    let summary = MeetingSummary(
      status: .completed,
      overview: "A brief meeting.",
      keyPoints: ["Finding"],
      decisions: ["Decision"],
      openItems: ["Open item"],
      participantContributions: ["Contribution"],
      actionItems: [.init(task: "Action")],
      risksAndFollowUpQuestions: ["Risk"],
      meetingStatus: Array(repeating: "status", count: 30).joined(separator: " "),
      model: "local-model",
      sourceFingerprint: "abc"
    )
    let budget = MeetingSummaryLengthBudget.calibrated(
      duration: 47,
      transcript: "A brief meeting."
    )

    let limited = summary.limited(to: budget)

    XCTAssertEqual(limited.actionItems.count, 1)
    XCTAssertEqual(limited.decisions, ["Decision"])
    XCTAssertEqual(limited.openItems, ["Open item"])
    XCTAssertTrue(limited.risksAndFollowUpQuestions.isEmpty)
    XCTAssertTrue(limited.keyPoints.isEmpty)
    XCTAssertTrue(limited.participantContributions.isEmpty)
    XCTAssertEqual(limited.meetingStatus.split(separator: " ").count, 20)
  }

  func testTranscriptionSpeakerMetadataRoundTrips() throws {
    let profileID = UUID()
    var transcription = makeRecording(transcriptionText: "Hello world").transcription
    transcription?.speakerEmbeddings = ["speaker-0": [0.1, 0.2]]
    transcription?.speakerProfileIDs = ["speaker-0": profileID]
    transcription?.speakerNames = ["speaker-0": "Alice"]

    let decoded = try JSONDecoder().decode(
      Transcription.self,
      from: JSONEncoder().encode(XCTUnwrap(transcription))
    )

    XCTAssertEqual(decoded.speakerEmbeddings, ["speaker-0": [0.1, 0.2]])
    XCTAssertEqual(decoded.speakerProfileIDs, ["speaker-0": profileID])
    XCTAssertEqual(decoded.speakerNames, ["speaker-0": "Alice"])
  }

  func testOlderTranscriptionWithoutSpeakerMetadataDefaultsToEmpty() throws {
    let transcription = try XCTUnwrap(makeRecording(transcriptionText: "Hello").transcription)
    let data = try JSONEncoder().encode(transcription)
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "speakerEmbeddings")
    object.removeValue(forKey: "speakerProfileIDs")
    object.removeValue(forKey: "speakerNames")

    let decoded = try JSONDecoder().decode(
      Transcription.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertEqual(decoded.speakerEmbeddings, [:])
    XCTAssertEqual(decoded.speakerProfileIDs, [:])
    XCTAssertEqual(decoded.speakerNames, [:])
  }

  private func makeRecording(transcriptionText: String) -> RecordingInfo {
    RecordingInfo(
      fileName: "test.wav",
      date: Date(timeIntervalSince1970: 0),
      transcription: Transcription(
        fileName: "test.wav",
        parameters: .init(),
        model: "tiny.en",
        status: .done(Date(timeIntervalSince1970: 1)),
        text: transcriptionText
      )
    )
  }
}
