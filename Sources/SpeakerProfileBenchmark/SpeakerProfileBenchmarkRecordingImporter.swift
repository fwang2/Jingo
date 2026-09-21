import Foundation

// MARK: - SpeakerProfileBenchmarkRecordingImporter

public enum SpeakerProfileBenchmarkRecordingImporter {
  public static func dataset(from data: Data) throws -> SpeakerProfileBenchmarkDataset {
    let recordings = try JSONDecoder().decode([StoredRecording].self, from: data)
      .sorted {
        if $0.createdAt == $1.createdAt {
          return $0.id.uuidString < $1.id.uuidString
        }
        return $0.createdAt < $1.createdAt
      }

    var speakerPseudonyms: [String: String] = [:]
    var observations: [SpeakerProfileBenchmarkObservation] = []
    for (recordingIndex, recording) in recordings.enumerated() {
      let manualNames = recording.manuallyAssignedSpeakerNames ?? [:]
      for speakerID in manualNames.keys.sorted() {
        guard let name = manualNames[speakerID]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              let embedding = recording.speakerEmbeddings?[speakerID]
        else {
          continue
        }

        let canonicalName = name.lowercased()
        let pseudonym = speakerPseudonyms[canonicalName] ?? {
          let value = String(format: "speaker-%03d", speakerPseudonyms.count + 1)
          speakerPseudonyms[canonicalName] = value
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

// MARK: - SpeakerProfileBenchmarkRecordingImportError

public enum SpeakerProfileBenchmarkRecordingImportError: LocalizedError, Equatable, Sendable {
  case noConfirmedSpeakers

  public var errorDescription: String? {
    switch self {
    case .noConfirmedSpeakers:
      "No recordings contained both a manually assigned speaker name and an embedding."
    }
  }
}

// MARK: - StoredRecording

private struct StoredRecording: Decodable {
  let id: UUID
  let createdAt: Date
  let speakerEmbeddings: [String: [Float]]?
  let manuallyAssignedSpeakerNames: [String: String]?
}
