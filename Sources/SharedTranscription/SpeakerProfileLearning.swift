import Foundation

// MARK: - SpeakerVoiceSampleSource

public enum SpeakerVoiceSampleSource: String, Codable, Equatable, Sendable {
  case legacy
  case voiceRecording
  case confirmedRecording
}

// MARK: - SpeakerVoiceSample

public struct SpeakerVoiceSample: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var embedding: [Float]
  public let source: SpeakerVoiceSampleSource
  public let sourceRecordingID: String?
  public let sourceSpeakerID: String?
  public let createdAt: Date
  public let qualityScore: Float?

  public init(
    id: UUID = UUID(),
    embedding: [Float],
    source: SpeakerVoiceSampleSource,
    sourceRecordingID: String? = nil,
    sourceSpeakerID: String? = nil,
    createdAt: Date = Date(),
    qualityScore: Float? = nil
  ) {
    self.id = id
    self.embedding = embedding
    self.source = source
    self.sourceRecordingID = sourceRecordingID
    self.sourceSpeakerID = sourceSpeakerID
    self.createdAt = createdAt
    self.qualityScore = qualityScore
  }
}

// MARK: - SpeakerProfileLearningResult

public struct SpeakerProfileLearningResult: Equatable, Sendable {
  public enum Outcome: Equatable, Sendable {
    case created
    case addedCoverage
    case duplicate
    case pending
  }

  public let profileID: UUID
  public let outcome: Outcome

  public init(profileID: UUID, outcome: Outcome) {
    self.profileID = profileID
    self.outcome = outcome
  }
}

// MARK: - SpeakerProfileMatcher Learning

public extension SpeakerProfileMatcher {
  @discardableResult
  static func enroll(
    name: String,
    embedding: [Float],
    linkedProfileID: UUID?,
    profiles: inout [SpeakerProfile],
    source: SpeakerVoiceSampleSource = .voiceRecording,
    sourceRecordingID: String? = nil,
    sourceSpeakerID: String? = nil,
    qualityScore: Float? = nil,
    now: Date = Date()
  ) -> UUID? {
    learn(
      name: name,
      embedding: embedding,
      linkedProfileID: linkedProfileID,
      profiles: &profiles,
      source: source,
      sourceRecordingID: sourceRecordingID,
      sourceSpeakerID: sourceSpeakerID,
      qualityScore: qualityScore,
      now: now
    )?.profileID
  }

  @discardableResult
  static func learn(
    name: String,
    embedding: [Float],
    linkedProfileID: UUID?,
    profiles: inout [SpeakerProfile],
    source: SpeakerVoiceSampleSource,
    sourceRecordingID: String? = nil,
    sourceSpeakerID: String? = nil,
    qualityScore: Float? = nil,
    now: Date = Date()
  ) -> SpeakerProfileLearningResult? {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty,
          let normalizedEmbedding = normalizedLearningEmbedding(embedding)
    else {
      return nil
    }

    let sample = SpeakerVoiceSample(
      embedding: normalizedEmbedding,
      source: source,
      sourceRecordingID: sourceRecordingID,
      sourceSpeakerID: sourceSpeakerID,
      createdAt: now,
      qualityScore: qualityScore
    )

    let profileIndex: Int? = if let linkedProfileID,
                                let index = profiles.firstIndex(where: { $0.id == linkedProfileID }),
                                profiles[index].name.caseInsensitiveCompare(trimmedName) == .orderedSame {
      index
    } else {
      profiles.firstIndex(where: {
        $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
      })
    }

    let profileID = profileIndex.map { profiles[$0].id }
    if source == .confirmedRecording,
       let sourceRecordingID,
       let sourceSpeakerID {
      removeObservation(
        sourceRecordingID: sourceRecordingID,
        sourceSpeakerID: sourceSpeakerID,
        excluding: profileID,
        profiles: &profiles
      )
    }

    guard let profileIndex, let profileID else {
      let profile = SpeakerProfile(
        name: trimmedName,
        voiceSamples: [sample],
        sampleCount: 1,
        updatedAt: now
      )
      profiles.append(profile)
      return SpeakerProfileLearningResult(profileID: profile.id, outcome: .created)
    }

    let outcome = add(sample, to: &profiles[profileIndex], now: now)
    profiles[profileIndex].name = trimmedName
    return SpeakerProfileLearningResult(profileID: profileID, outcome: outcome)
  }

  static func removeObservation(
    sourceRecordingID: String,
    sourceSpeakerID: String,
    excluding excludedProfileID: UUID? = nil,
    profiles: inout [SpeakerProfile]
  ) {
    for index in profiles.indices where profiles[index].id != excludedProfileID {
      let activeCount = profiles[index].voiceSamples.count
      profiles[index].voiceSamples.removeAll {
        isSameSource(
          $0,
          sourceRecordingID: sourceRecordingID,
          sourceSpeakerID: sourceSpeakerID
        )
      }
      profiles[index].pendingVoiceSamples.removeAll {
        isSameSource(
          $0,
          sourceRecordingID: sourceRecordingID,
          sourceSpeakerID: sourceSpeakerID
        )
      }
      let removedCount = activeCount - profiles[index].voiceSamples.count
      if removedCount > 0 {
        profiles[index].sampleCount = max(
          profiles[index].voiceSamples.count,
          profiles[index].sampleCount - removedCount
        )
      }
    }
  }
}

// MARK: - Private Helpers

private extension SpeakerProfileMatcher {
  static var diversityReplacementMargin: Float {
    0.02
  }

  static func add(
    _ sample: SpeakerVoiceSample,
    to profile: inout SpeakerProfile,
    now: Date
  ) -> SpeakerProfileLearningResult.Outcome {
    if hasSameSource(sample, in: profile) {
      return .duplicate
    }

    let activeSimilarities = profile.voiceSamples.compactMap {
      cosineSimilarity(sample.embedding, $0.embedding)
    }
    if let closestActive = activeSimilarities.max(),
       closestActive >= duplicateSampleSimilarity {
      return .duplicate
    }

    if profile.voiceSamples.isEmpty {
      profile.voiceSamples = [sample]
      profile.sampleCount = max(profile.sampleCount, 1)
      profile.updatedAt = now
      return .addedCoverage
    }

    let closestActive = activeSimilarities.max() ?? -1
    if sample.source == .confirmedRecording,
       closestActive < activeSampleSimilarity {
      if let corroboratingIndex = profile.pendingVoiceSamples.firstIndex(where: {
        cosineSimilarity(sample.embedding, $0.embedding)
          .map { $0 >= pendingSampleCorroborationSimilarity } ?? false
      }) {
        let corroboratingSample = profile.pendingVoiceSamples.remove(at: corroboratingIndex)
        let promotedSample = preferredSample(sample, corroboratingSample)
        let wasAdded = addActiveSample(promotedSample, to: &profile)
        if wasAdded {
          profile.sampleCount += 1
          profile.updatedAt = now
          return .addedCoverage
        }
        return .duplicate
      }

      profile.pendingVoiceSamples.append(sample)
      profile.pendingVoiceSamples.sort { $0.createdAt < $1.createdAt }
      if profile.pendingVoiceSamples.count > maximumPendingSamples {
        profile.pendingVoiceSamples.removeFirst(
          profile.pendingVoiceSamples.count - maximumPendingSamples
        )
      }
      profile.updatedAt = now
      return .pending
    }

    guard addActiveSample(sample, to: &profile) else {
      return .duplicate
    }
    profile.sampleCount += 1
    profile.updatedAt = now
    return .addedCoverage
  }

  static func addActiveSample(
    _ sample: SpeakerVoiceSample,
    to profile: inout SpeakerProfile
  ) -> Bool {
    guard profile.voiceSamples.count >= maximumActiveSamples else {
      profile.voiceSamples.append(sample)
      return true
    }

    let replaceableIndices = profile.voiceSamples.indices.filter {
      profile.voiceSamples[$0].source != .voiceRecording
    }
    guard !replaceableIndices.isEmpty else {
      return false
    }

    let candidateClosestSimilarity = profile.voiceSamples.compactMap {
      cosineSimilarity(sample.embedding, $0.embedding)
    }
    .max() ?? 1

    let mostRedundant = replaceableIndices.compactMap { index -> (Int, Float)? in
      let similarity = profile.voiceSamples.indices
        .filter { $0 != index }
        .compactMap {
          cosineSimilarity(
            profile.voiceSamples[index].embedding,
            profile.voiceSamples[$0].embedding
          )
        }
        .max()
      return similarity.map { (index, $0) }
    }
    .max { $0.1 < $1.1 }

    guard let mostRedundant,
          candidateClosestSimilarity + diversityReplacementMargin < mostRedundant.1
    else {
      return false
    }
    profile.voiceSamples[mostRedundant.0] = sample
    return true
  }

  static func preferredSample(
    _ lhs: SpeakerVoiceSample,
    _ rhs: SpeakerVoiceSample
  ) -> SpeakerVoiceSample {
    let lhsQuality = lhs.qualityScore ?? 0
    let rhsQuality = rhs.qualityScore ?? 0
    if lhsQuality == rhsQuality {
      return lhs.createdAt >= rhs.createdAt ? lhs : rhs
    }
    return lhsQuality > rhsQuality ? lhs : rhs
  }

  static func hasSameSource(
    _ sample: SpeakerVoiceSample,
    in profile: SpeakerProfile
  ) -> Bool {
    guard let sourceRecordingID = sample.sourceRecordingID,
          let sourceSpeakerID = sample.sourceSpeakerID
    else {
      return false
    }
    return (profile.voiceSamples + profile.pendingVoiceSamples).contains {
      isSameSource(
        $0,
        sourceRecordingID: sourceRecordingID,
        sourceSpeakerID: sourceSpeakerID
      )
    }
  }

  static func isSameSource(
    _ sample: SpeakerVoiceSample,
    sourceRecordingID: String,
    sourceSpeakerID: String
  ) -> Bool {
    sample.sourceRecordingID == sourceRecordingID
      && sample.sourceSpeakerID == sourceSpeakerID
  }

  static func normalizedLearningEmbedding(_ embedding: [Float]) -> [Float]? {
    guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else {
      return nil
    }
    let magnitude = sqrt(embedding.reduce(into: Float.zero) { $0 += $1 * $1 })
    guard magnitude > 0 else {
      return nil
    }
    return embedding.map { $0 / magnitude }
  }
}
