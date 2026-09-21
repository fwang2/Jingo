import Foundation

// MARK: - SpeakerProfile

public struct SpeakerProfile: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var voiceSamples: [SpeakerVoiceSample]
  public var pendingVoiceSamples: [SpeakerVoiceSample]
  public var sampleCount: Int
  public var updatedAt: Date

  public var embedding: [Float] {
    voiceSamples.first?.embedding ?? []
  }

  public init(
    id: UUID = UUID(),
    name: String,
    embedding: [Float],
    sampleCount: Int = 1,
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    voiceSamples = embedding.isEmpty
      ? []
      : [SpeakerVoiceSample(embedding: embedding, source: .legacy, createdAt: updatedAt)]
    pendingVoiceSamples = []
    self.sampleCount = max(sampleCount, 1)
    self.updatedAt = updatedAt
  }

  public init(
    id: UUID = UUID(),
    name: String,
    voiceSamples: [SpeakerVoiceSample],
    pendingVoiceSamples: [SpeakerVoiceSample] = [],
    sampleCount: Int? = nil,
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.voiceSamples = voiceSamples
    self.pendingVoiceSamples = pendingVoiceSamples
    self.sampleCount = max(sampleCount ?? voiceSamples.count, voiceSamples.isEmpty ? 0 : 1)
    self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, embedding, sampleCount, updatedAt
    case voiceSamples, pendingVoiceSamples
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    sampleCount = try container.decodeIfPresent(Int.self, forKey: .sampleCount) ?? 1
    updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()

    if let decodedSamples = try container.decodeIfPresent(
      [SpeakerVoiceSample].self,
      forKey: .voiceSamples
    ) {
      voiceSamples = decodedSamples
    } else {
      let legacyEmbedding = try container.decodeIfPresent([Float].self, forKey: .embedding) ?? []
      voiceSamples = legacyEmbedding.isEmpty
        ? []
        : [
          SpeakerVoiceSample(
            embedding: legacyEmbedding,
            source: .legacy,
            createdAt: updatedAt
          ),
        ]
    }
    pendingVoiceSamples = try container.decodeIfPresent(
      [SpeakerVoiceSample].self,
      forKey: .pendingVoiceSamples
    ) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(embedding, forKey: .embedding)
    try container.encode(sampleCount, forKey: .sampleCount)
    try container.encode(updatedAt, forKey: .updatedAt)
    try container.encode(voiceSamples, forKey: .voiceSamples)
    if !pendingVoiceSamples.isEmpty {
      try container.encode(pendingVoiceSamples, forKey: .pendingVoiceSamples)
    }
  }
}

// MARK: - SpeakerProfileMatch

public struct SpeakerProfileMatch: Equatable, Sendable {
  public let speakerID: String
  public let profileID: UUID
  public let name: String
  public let similarity: Float

  public init(speakerID: String, profileID: UUID, name: String, similarity: Float) {
    self.speakerID = speakerID
    self.profileID = profileID
    self.name = name
    self.similarity = similarity
  }
}

// MARK: - SpeakerProfileEnrollmentError

public enum SpeakerProfileEnrollmentError: LocalizedError, Equatable, Sendable {
  case duplicateName
  case emptyName
  case insufficientSpeech
  case multipleSpeakers
  case missingEmbedding

  public var errorDescription: String? {
    switch self {
    case .duplicateName:
      "A speaker with this name already exists."

    case .emptyName:
      "Enter a name for this speaker."

    case .insufficientSpeech:
      "Record at least 6 seconds of clear speech."

    case .multipleSpeakers:
      "The sample contains more than one prominent speaker. Record one person in a quiet place."

    case .missingEmbedding:
      "A usable voice profile could not be created from this sample."
    }
  }
}

// MARK: - SpeakerProfileMatcher

public enum SpeakerProfileMatcher {
  // FluidAudio's offline clustering uses a 0.6 Euclidean boundary for unit vectors,
  // which corresponds to 0.82 cosine similarity. Across recording conditions, allow
  // a lower score only when the best profile is clearly separated from the runner-up.
  public static let defaultMinimumSimilarity: Float = 0.82
  public static let defaultMinimumMargin: Float = 0.05
  public static let fallbackMinimumSimilarity: Float = 0.60
  public static let fallbackMinimumMargin: Float = 0.20
  public static let minimumEnrollmentSpeechMS: Int64 = 6000
  public static let minimumEnrollmentDominance: Double = 0.85
  public static let duplicateSampleSimilarity: Float = 0.92
  public static let activeSampleSimilarity: Float = 0.72
  public static let pendingSampleCorroborationSimilarity: Float = 0.84
  public static let maximumActiveSamples = 10
  public static let maximumPendingSamples = 3

  public static func validatedName(
    _ name: String,
    excluding profileID: UUID? = nil,
    profiles: [SpeakerProfile]
  ) throws -> String {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw SpeakerProfileEnrollmentError.emptyName
    }
    guard !profiles.contains(where: {
      $0.id != profileID && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
    }) else {
      throw SpeakerProfileEnrollmentError.duplicateName
    }
    return trimmedName
  }

  @discardableResult
  public static func rename(
    profileID: UUID,
    to name: String,
    profiles: inout [SpeakerProfile],
    now: Date = Date()
  ) throws -> String {
    let trimmedName = try validatedName(name, excluding: profileID, profiles: profiles)
    guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
      throw SpeakerProfileEnrollmentError.missingEmbedding
    }
    profiles[index].name = trimmedName
    profiles[index].updatedAt = now
    return trimmedName
  }

  public static func enrollmentEmbedding(
    speechDurationMSBySpeaker: [String: Int64],
    speakerEmbeddings: [String: [Float]],
    minimumSpeechMS: Int64 = minimumEnrollmentSpeechMS,
    minimumDominance: Double = minimumEnrollmentDominance
  ) throws -> [Float] {
    let durations = speechDurationMSBySpeaker.filter { $0.value > 0 }
    guard let dominant = durations.max(by: { $0.value < $1.value }),
          dominant.value >= minimumSpeechMS
    else {
      throw SpeakerProfileEnrollmentError.insufficientSpeech
    }

    let totalSpeechMS = durations.values.reduce(Int64.zero, +)
    guard totalSpeechMS > 0,
          Double(dominant.value) / Double(totalSpeechMS) >= minimumDominance
    else {
      throw SpeakerProfileEnrollmentError.multipleSpeakers
    }
    guard let embedding = speakerEmbeddings[dominant.key],
          let normalizedEmbedding = normalized(embedding)
    else {
      throw SpeakerProfileEnrollmentError.missingEmbedding
    }
    return normalizedEmbedding
  }

  public static func matches(
    speakerEmbeddings: [String: [Float]],
    profiles: [SpeakerProfile],
    minimumSimilarity: Float = defaultMinimumSimilarity,
    minimumMargin: Float = defaultMinimumMargin,
    fallbackSimilarity: Float? = nil,
    fallbackMargin: Float = fallbackMinimumMargin
  ) -> [String: SpeakerProfileMatch] {
    matches(
      speakerEmbeddingCandidates: speakerEmbeddings.mapValues { [$0] },
      profiles: profiles,
      minimumSimilarity: minimumSimilarity,
      minimumMargin: minimumMargin,
      fallbackSimilarity: fallbackSimilarity,
      fallbackMargin: fallbackMargin
    )
  }

  public static func matches(
    speakerEmbeddingCandidates: [String: [[Float]]],
    profiles: [SpeakerProfile],
    minimumSimilarity: Float = defaultMinimumSimilarity,
    minimumMargin: Float = defaultMinimumMargin,
    fallbackSimilarity: Float? = nil,
    fallbackMargin: Float = fallbackMinimumMargin
  ) -> [String: SpeakerProfileMatch] {
    struct Candidate {
      let speakerID: String
      let profile: SpeakerProfile
      let similarity: Float
    }

    var candidates: [Candidate] = []
    for (speakerID, embeddings) in speakerEmbeddingCandidates {
      let ranked = profiles.compactMap { profile -> Candidate? in
        guard let similarity = profileSimilarity(
          queryEmbeddings: embeddings,
          profile: profile
        ) else {
          return nil
        }
        return Candidate(speakerID: speakerID, profile: profile, similarity: similarity)
      }
      .sorted {
        if $0.similarity == $1.similarity {
          return $0.profile.id.uuidString < $1.profile.id.uuidString
        }
        return $0.similarity > $1.similarity
      }

      guard let best = ranked.first else { continue }
      let margin = ranked.dropFirst().first.map {
        best.similarity - $0.similarity
      } ?? .infinity
      let isStrongMatch = best.similarity >= minimumSimilarity
        && margin >= minimumMargin
      let isClearFallbackMatch = fallbackSimilarity.map {
        best.similarity >= $0 && margin >= fallbackMargin
      } ?? false
      guard isStrongMatch || isClearFallbackMatch else {
        continue
      }
      candidates.append(best)
    }

    candidates.sort {
      if $0.similarity == $1.similarity {
        return $0.speakerID < $1.speakerID
      }
      return $0.similarity > $1.similarity
    }

    var matchedSpeakers = Set<String>()
    var matchedProfiles = Set<UUID>()
    var result: [String: SpeakerProfileMatch] = [:]
    for candidate in candidates
      where !matchedSpeakers.contains(candidate.speakerID)
      && !matchedProfiles.contains(candidate.profile.id) {
      result[candidate.speakerID] = SpeakerProfileMatch(
        speakerID: candidate.speakerID,
        profileID: candidate.profile.id,
        name: candidate.profile.name,
        similarity: candidate.similarity
      )
      matchedSpeakers.insert(candidate.speakerID)
      matchedProfiles.insert(candidate.profile.id)
    }
    return result
  }

  private static func profileSimilarity(
    queryEmbeddings: [[Float]],
    profile: SpeakerProfile
  ) -> Float? {
    let perQueryBest = queryEmbeddings
      .compactMap { queryEmbedding in
        profile.voiceSamples
          .compactMap {
            cosineSimilarity(queryEmbedding, $0.embedding)
          }
          .max()
      }
      .sorted(by: >)
    guard !perQueryBest.isEmpty else {
      return nil
    }

    let retainedCount = max(1, (perQueryBest.count + 1) / 2)
    let retained = perQueryBest.prefix(retainedCount)
    return retained.reduce(Float.zero, +) / Float(retainedCount)
  }

  public static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float? {
    guard !lhs.isEmpty, lhs.count == rhs.count,
          lhs.allSatisfy(\.isFinite), rhs.allSatisfy(\.isFinite)
    else {
      return nil
    }

    var dot: Float = 0
    var lhsMagnitude: Float = 0
    var rhsMagnitude: Float = 0
    for (left, right) in zip(lhs, rhs) {
      dot += left * right
      lhsMagnitude += left * left
      rhsMagnitude += right * right
    }
    guard lhsMagnitude > 0, rhsMagnitude > 0 else {
      return nil
    }
    return min(max(dot / sqrt(lhsMagnitude * rhsMagnitude), -1), 1)
  }

  private static func normalized(_ embedding: [Float]) -> [Float]? {
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
