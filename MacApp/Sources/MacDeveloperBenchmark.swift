#if DEBUG
  import AppKit
  import Foundation
  import SpeakerProfileBenchmarkCore
  import UniformTypeIdentifiers

  // MARK: - MacDeveloperBenchmarkResult

  struct MacDeveloperBenchmarkResult {
    let reportText: String
    let datasetData: Data
    let observations: Int
    let speakers: Int
    let meetings: Int
    let knownTrials: Int
    let legacyKnownIdentificationRate: Double
    let bankKnownIdentificationRate: Double
    let legacyMisidentificationRate: Double
    let bankMisidentificationRate: Double
    let legacyFalseAcceptanceRate: Double
    let bankFalseAcceptanceRate: Double

    var scopeDescription: String {
      "\(observations) samples · \(speakers) speakers · \(meetings) meetings"
    }
  }

  // MARK: - MacDeveloperBenchmark

  enum MacDeveloperBenchmark {
    static func confirmedSampleCount(in recordings: [MacRecording]) -> Int {
      recordings.reduce(into: 0) { count, recording in
        for speakerID in (recording.manuallyAssignedSpeakerNames ?? [:]).keys
          where recording.speakerEmbeddings?[speakerID] != nil {
          count += 1
        }
      }
    }

    static func run(recordings: [MacRecording]) throws -> MacDeveloperBenchmarkResult {
      let dataset = try dataset(from: recordings)
      let report = try SpeakerProfileBenchmarkEngine.run(dataset: dataset)
      guard let highlightedRun = report.runs.min(by: {
        abs($0.threshold - SpeakerProfileMatcher.defaultMinimumSimilarity)
          < abs($1.threshold - SpeakerProfileMatcher.defaultMinimumSimilarity)
      }) else {
        throw MacDeveloperBenchmarkError.missingResult
      }

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let datasetData = try encoder.encode(dataset)
      let legacy = highlightedRun.legacyAverage.metrics
      let bank = highlightedRun.representativeBank.metrics
      return MacDeveloperBenchmarkResult(
        reportText: SpeakerProfileBenchmarkRenderer.markdown(report),
        datasetData: datasetData,
        observations: report.dataset.observations,
        speakers: report.dataset.speakers,
        meetings: report.dataset.meetings,
        knownTrials: bank.knownTrials,
        legacyKnownIdentificationRate: legacy.knownIdentificationRate,
        bankKnownIdentificationRate: bank.knownIdentificationRate,
        legacyMisidentificationRate: legacy.misidentificationRate,
        bankMisidentificationRate: bank.misidentificationRate,
        legacyFalseAcceptanceRate: legacy.falseAcceptanceRate,
        bankFalseAcceptanceRate: bank.falseAcceptanceRate
      )
    }

    private static func dataset(
      from recordings: [MacRecording]
    ) throws -> SpeakerProfileBenchmarkDataset {
      let sortedRecordings = recordings.sorted {
        if $0.createdAt == $1.createdAt {
          return $0.id.uuidString < $1.id.uuidString
        }
        return $0.createdAt < $1.createdAt
      }
      var pseudonyms: [String: String] = [:]
      var observations: [SpeakerProfileBenchmarkObservation] = []

      for (recordingIndex, recording) in sortedRecordings.enumerated() {
        let manualNames = recording.manuallyAssignedSpeakerNames ?? [:]
        for speakerID in manualNames.keys.sorted() {
          guard let name = manualNames[speakerID]?.trimmingCharacters(
            in: .whitespacesAndNewlines
          ),
            !name.isEmpty,
            let embedding = recording.speakerEmbeddings?[speakerID]
          else {
            continue
          }

          let canonicalName = name.lowercased()
          let pseudonym = pseudonyms[canonicalName] ?? {
            let value = String(format: "speaker-%03d", pseudonyms.count + 1)
            pseudonyms[canonicalName] = value
            return value
          }()
          observations.append(SpeakerProfileBenchmarkObservation(
            id: String(format: "observation-%04d", observations.count + 1),
            sequence: observations.count + 1,
            speakerID: pseudonym,
            meetingID: String(format: "meeting-%04d", recordingIndex + 1),
            mode: .confirmedMeeting,
            embedding: embedding,
            conditions: ["source": "recording-index"]
          ))
        }
      }

      guard !observations.isEmpty else {
        throw SpeakerProfileBenchmarkRecordingImportError.noConfirmedSpeakers
      }
      return SpeakerProfileBenchmarkDataset(observations: observations)
    }
  }

  // MARK: - MacDeveloperBenchmarkExporter

  @MainActor
  enum MacDeveloperBenchmarkExporter {
    static func save(
      _ data: Data,
      suggestedName: String,
      allowedFileType: String
    ) throws {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = suggestedName
      if let contentType = UTType(filenameExtension: allowedFileType) {
        panel.allowedContentTypes = [contentType]
      }
      guard panel.runModal() == .OK, let url = panel.url else {
        return
      }
      try data.write(to: url, options: .atomic)
    }
  }

  // MARK: - MacDeveloperBenchmarkError

  private enum MacDeveloperBenchmarkError: LocalizedError {
    case missingResult

    var errorDescription: String? {
      "The benchmark did not produce a result."
    }
  }
#endif
