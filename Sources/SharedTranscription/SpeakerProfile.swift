import Foundation

// MARK: - SpeakerProfile

public struct SpeakerProfile: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var embedding: [Float]
  public var sampleCount: Int
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    name: String,
    embedding: [Float],
    sampleCount: Int = 1,
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.embedding = embedding
    self.sampleCount = max(sampleCount, 1)
    self.updatedAt = updatedAt
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
        let similarities = embeddings.compactMap {
          cosineSimilarity($0, profile.embedding)
        }
        guard let similarity = similarities.max() else {
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

  @discardableResult
  public static func enroll(
    name: String,
    embedding: [Float],
    linkedProfileID: UUID?,
    profiles: inout [SpeakerProfile],
    now: Date = Date()
  ) -> UUID? {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, let normalizedEmbedding = normalized(embedding) else {
      return nil
    }

    if let linkedProfileID,
       let index = profiles.firstIndex(where: { $0.id == linkedProfileID }),
       profiles[index].name.caseInsensitiveCompare(trimmedName) == .orderedSame,
       profiles[index].embedding.count == normalizedEmbedding.count {
      merge(
        normalizedEmbedding,
        into: &profiles[index],
        name: trimmedName,
        now: now
      )
      return linkedProfileID
    }

    if let index = profiles.firstIndex(where: {
      $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame
        && $0.embedding.count == normalizedEmbedding.count
    }) {
      merge(
        normalizedEmbedding,
        into: &profiles[index],
        name: trimmedName,
        now: now
      )
      return profiles[index].id
    }

    let profile = SpeakerProfile(
      name: trimmedName,
      embedding: normalizedEmbedding,
      updatedAt: now
    )
    profiles.append(profile)
    return profile.id
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
    guard lhsMagnitude > 0, rhsMagnitude > 0 else { return nil }
    return min(max(dot / sqrt(lhsMagnitude * rhsMagnitude), -1), 1)
  }

  private static func normalized(_ embedding: [Float]) -> [Float]? {
    guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else { return nil }
    let magnitude = sqrt(embedding.reduce(into: Float.zero) { $0 += $1 * $1 })
    guard magnitude > 0 else { return nil }
    return embedding.map { $0 / magnitude }
  }

  private static func merge(
    _ normalizedEmbedding: [Float],
    into profile: inout SpeakerProfile,
    name: String,
    now: Date
  ) {
    let count = max(profile.sampleCount, 1)
    let oldEmbedding = normalized(profile.embedding) ?? profile.embedding
    let merged = zip(oldEmbedding, normalizedEmbedding).map { oldValue, newValue in
      (oldValue * Float(count) + newValue) / Float(count + 1)
    }
    profile.embedding = normalized(merged) ?? merged
    profile.sampleCount = count + 1
    profile.name = name
    profile.updatedAt = now
  }
}
