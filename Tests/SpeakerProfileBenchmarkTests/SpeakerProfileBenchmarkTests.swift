import SpeakerProfileBenchmarkCore
import XCTest

// SpeakerProfileBenchmarkTests does not link CustomDump.
// swiftlint:disable xctassertnodifference_preferred
final class SpeakerProfileBenchmarkTests: XCTestCase {
  func testRepresentativeBankOutperformsLegacyAverageAcrossVoiceConditions() throws {
    let report = try SpeakerProfileBenchmarkEngine.run(
      dataset: Self.fixture,
      thresholds: [0.82],
      margin: 0.05
    )
    let run = try XCTUnwrap(report.runs.first)

    XCTAssertGreaterThan(
      run.representativeBank.metrics.correctKnown,
      run.legacyAverage.metrics.correctKnown
    )
    XCTAssertEqual(
      run.representativeBank.metrics.falseAcceptanceRate,
      run.legacyAverage.metrics.falseAcceptanceRate
    )
    XCTAssertEqual(run.representativeBank.learning.pending, 1)
    XCTAssertEqual(run.representativeBank.learning.duplicate, 1)
    XCTAssertEqual(run.representativeBank.finalPendingSamples, 0)
  }

  func testThresholdSweepIsSortedAndConditionSlicesAreReported() throws {
    let report = try SpeakerProfileBenchmarkEngine.run(
      dataset: Self.fixture,
      thresholds: [0.90, 0.70, 0.82, 0.70]
    )

    XCTAssertEqual(report.runs.map(\.threshold), [0.70, 0.82, 0.90])
    XCTAssertTrue(report.runs.allSatisfy {
      $0.conditionSlices.contains { $0.condition == "device=laptop" }
    })
    XCTAssertTrue(SpeakerProfileBenchmarkRenderer.markdown(report).contains("Representative bank"))
  }

  func testRejectsDimensionMismatch() {
    let dataset = SpeakerProfileBenchmarkDataset(observations: [
      .init(
        id: "enroll-alice",
        sequence: 1,
        speakerID: "speaker-a",
        meetingID: "enrollment-a",
        mode: .enrollment,
        embedding: [1, 0]
      ),
      .init(
        id: "evaluate-alice",
        sequence: 2,
        speakerID: "speaker-a",
        meetingID: "meeting-1",
        mode: .evaluationOnly,
        embedding: [1, 0, 0]
      ),
    ])

    XCTAssertThrowsError(try SpeakerProfileBenchmarkEngine.run(dataset: dataset))
  }

  func testRecordingImporterUsesOnlyManualNamesAndPseudonymizesThem() throws {
    let data = Data(Self.recordingsJSON.utf8)
    let dataset = try SpeakerProfileBenchmarkRecordingImporter.dataset(from: data)

    XCTAssertEqual(dataset.observations.count, 2)
    XCTAssertEqual(dataset.observations.map(\.speakerID), ["speaker-001", "speaker-001"])
    XCTAssertEqual(dataset.observations.map(\.meetingID), ["meeting-0001", "meeting-0002"])
    XCTAssertTrue(dataset.observations.allSatisfy { $0.mode == .confirmedMeeting })
    XCTAssertFalse(try String(data: JSONEncoder().encode(dataset), encoding: .utf8)?.contains("Alice") == true)
  }

  private static let fixture = SpeakerProfileBenchmarkDataset(observations: [
    .init(
      id: "enroll-alice",
      sequence: 1,
      speakerID: "speaker-a",
      meetingID: "enrollment-a",
      mode: .enrollment,
      embedding: [1, 0, 0],
      conditions: ["device": "laptop", "setting": "quiet"]
    ),
    .init(
      id: "enroll-bob",
      sequence: 2,
      speakerID: "speaker-b",
      meetingID: "enrollment-b",
      mode: .enrollment,
      embedding: [0, 1, 0],
      conditions: ["device": "laptop", "setting": "quiet"]
    ),
    .init(
      id: "alice-phone-first",
      sequence: 3,
      speakerID: "speaker-a",
      meetingID: "meeting-1",
      mode: .confirmedMeeting,
      embedding: [0, 0, 1],
      conditions: ["device": "phone", "setting": "noisy"]
    ),
    .init(
      id: "alice-phone-second",
      sequence: 4,
      speakerID: "speaker-a",
      meetingID: "meeting-2",
      mode: .confirmedMeeting,
      embedding: [0.02, 0, 0.999],
      conditions: ["device": "phone", "setting": "noisy"]
    ),
    .init(
      id: "alice-laptop-return",
      sequence: 5,
      speakerID: "speaker-a",
      meetingID: "meeting-3",
      mode: .evaluationOnly,
      embedding: [0.999, 0, 0.02],
      conditions: ["device": "laptop", "setting": "quiet"]
    ),
    .init(
      id: "unknown-charlie",
      sequence: 6,
      speakerID: "speaker-c",
      meetingID: "meeting-4",
      mode: .evaluationOnly,
      embedding: [0.70, 0.70, 0],
      conditions: ["device": "laptop", "setting": "quiet"]
    ),
    .init(
      id: "alice-laptop-duplicate",
      sequence: 7,
      speakerID: "speaker-a",
      meetingID: "meeting-5",
      mode: .confirmedMeeting,
      embedding: [1, 0, 0],
      conditions: ["device": "laptop", "setting": "quiet"]
    ),
  ])

  private static let recordingsJSON = """
  [
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "createdAt": 100,
      "speakerEmbeddings": {
        "cluster-a": [1, 0, 0],
        "cluster-unconfirmed": [0, 1, 0]
      },
      "speakerNames": {
        "cluster-unconfirmed": "Automatic Name"
      },
      "manuallyAssignedSpeakerNames": {
        "cluster-a": "Alice"
      },
      "transcript": "This must not be exported."
    },
    {
      "id": "00000000-0000-0000-0000-000000000002",
      "createdAt": 200,
      "speakerEmbeddings": {
        "cluster-b": [0.9, 0.1, 0]
      },
      "manuallyAssignedSpeakerNames": {
        "cluster-b": "Alice"
      }
    }
  ]
  """
}

// swiftlint:enable xctassertnodifference_preferred
