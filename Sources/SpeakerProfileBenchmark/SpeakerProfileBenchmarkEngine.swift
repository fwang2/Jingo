import Foundation

// MARK: - SpeakerProfileBenchmarkEngine

public enum SpeakerProfileBenchmarkEngine {
  public static let defaultThresholds: [Float] = [0.60, 0.70, 0.75, 0.80, 0.82, 0.85, 0.90]

  public static func run(
    dataset: SpeakerProfileBenchmarkDataset,
    thresholds: [Float] = defaultThresholds,
    margin: Float = SpeakerProfileMatcher.defaultMinimumMargin
  ) throws -> SpeakerProfileBenchmarkReport {
    let dataset = try dataset.validated()
    guard margin >= 0, margin <= 1 else {
      throw SpeakerProfileBenchmarkError.invalidMargin(margin)
    }
    let uniqueThresholds = Array(Set(thresholds)).sorted()
    guard !uniqueThresholds.isEmpty else {
      throw SpeakerProfileBenchmarkError.invalidThreshold(.nan)
    }
    for threshold in uniqueThresholds where threshold < -1 || threshold > 1 || !threshold.isFinite {
      throw SpeakerProfileBenchmarkError.invalidThreshold(threshold)
    }

    let observations = dataset.observations.sorted {
      if $0.sequence == $1.sequence {
        return $0.id < $1.id
      }
      return $0.sequence < $1.sequence
    }
    let runs = uniqueThresholds.map {
      run(observations: observations, threshold: $0, margin: margin)
    }
    let summary = SpeakerProfileBenchmarkDatasetSummary(
      observations: observations.count,
      evaluations: observations.count { $0.mode != .enrollment },
      enrollments: observations.count { $0.mode == .enrollment },
      speakers: Set(observations.map(\.speakerID)).count,
      meetings: Set(observations.map(\.meetingID)).count
    )
    return SpeakerProfileBenchmarkReport(dataset: summary, margin: margin, runs: runs)
  }

  private static func run(
    observations: [SpeakerProfileBenchmarkObservation],
    threshold: Float,
    margin: Float
  ) -> SpeakerProfileBenchmarkRun {
    var legacyState = LegacyState()
    var representativeState = RepresentativeState()
    var learnedSpeakers = Set<String>()
    var accumulators = ReplayAccumulators()

    for observation in observations {
      let wasKnown = learnedSpeakers.contains(observation.speakerID)
      if observation.mode != .enrollment {
        evaluate(
          observation: observation,
          wasKnown: wasKnown,
          threshold: threshold,
          margin: margin,
          legacyState: legacyState,
          representativeState: representativeState,
          accumulators: &accumulators
        )
      }

      guard observation.mode != .evaluationOnly else {
        continue
      }
      legacyState.learn(observation)
      representativeState.learn(observation)
      learnedSpeakers.insert(observation.speakerID)
    }

    let allConditions = Set(accumulators.legacySlices.keys)
      .union(accumulators.representativeSlices.keys)
    let conditionSlices = allConditions.sorted().map {
      SpeakerProfileBenchmarkConditionSlice(
        condition: $0,
        legacyAverage: accumulators.legacySlices[$0, default: MetricsAccumulator()].metrics,
        representativeBank: accumulators.representativeSlices[
          $0,
          default: MetricsAccumulator()
        ].metrics
      )
    }
    return SpeakerProfileBenchmarkRun(
      threshold: threshold,
      legacyAverage: legacyState.result(metrics: accumulators.legacy.metrics),
      representativeBank: representativeState.result(metrics: accumulators.representative.metrics),
      conditionSlices: conditionSlices
    )
  }

  private static func evaluate(
    observation: SpeakerProfileBenchmarkObservation,
    wasKnown: Bool,
    threshold: Float,
    margin: Float,
    legacyState: LegacyState,
    representativeState: RepresentativeState,
    accumulators: inout ReplayAccumulators
  ) {
    let legacyPrediction = legacyState.match(
      queryEmbeddings: observation.queryEmbeddings,
      threshold: threshold,
      margin: margin
    )
    let representativePrediction = representativeState.match(
      queryEmbeddings: observation.queryEmbeddings,
      threshold: threshold,
      margin: margin
    )
    accumulators.legacy.record(
      expectedSpeaker: observation.speakerID,
      wasKnown: wasKnown,
      predictedSpeaker: legacyPrediction
    )
    accumulators.representative.record(
      expectedSpeaker: observation.speakerID,
      wasKnown: wasKnown,
      predictedSpeaker: representativePrediction
    )

    for condition in conditionKeys(observation.conditions) {
      accumulators.legacySlices[condition, default: MetricsAccumulator()].record(
        expectedSpeaker: observation.speakerID,
        wasKnown: wasKnown,
        predictedSpeaker: legacyPrediction
      )
      accumulators.representativeSlices[condition, default: MetricsAccumulator()].record(
        expectedSpeaker: observation.speakerID,
        wasKnown: wasKnown,
        predictedSpeaker: representativePrediction
      )
    }
  }

  private static func conditionKeys(_ conditions: [String: String]) -> [String] {
    conditions.map { "\($0.key)=\($0.value)" }.sorted()
  }
}

// MARK: - ReplayAccumulators

private struct ReplayAccumulators {
  var legacy = MetricsAccumulator()
  var representative = MetricsAccumulator()
  var legacySlices: [String: MetricsAccumulator] = [:]
  var representativeSlices: [String: MetricsAccumulator] = [:]
}

// MARK: - MetricsAccumulator

private struct MetricsAccumulator {
  var evaluations = 0
  var knownTrials = 0
  var unknownTrials = 0
  var correctKnown = 0
  var wrongKnown = 0
  var rejectedKnown = 0
  var rejectedUnknown = 0
  var acceptedUnknown = 0

  var metrics: SpeakerProfileBenchmarkMetrics {
    let correct = correctKnown + rejectedUnknown
    let incorrectNames = wrongKnown + acceptedUnknown
    return SpeakerProfileBenchmarkMetrics(
      evaluations: evaluations,
      knownTrials: knownTrials,
      unknownTrials: unknownTrials,
      correctKnown: correctKnown,
      wrongKnown: wrongKnown,
      rejectedKnown: rejectedKnown,
      rejectedUnknown: rejectedUnknown,
      acceptedUnknown: acceptedUnknown,
      overallAccuracy: ratio(correct, evaluations),
      knownIdentificationRate: ratio(correctKnown, knownTrials),
      misidentificationRate: ratio(incorrectNames, evaluations),
      falseRejectionRate: ratio(rejectedKnown, knownTrials),
      falseAcceptanceRate: ratio(acceptedUnknown, unknownTrials)
    )
  }

  mutating func record(
    expectedSpeaker: String,
    wasKnown: Bool,
    predictedSpeaker: String?
  ) {
    evaluations += 1
    if wasKnown {
      knownTrials += 1
      if predictedSpeaker == expectedSpeaker {
        correctKnown += 1
      } else if predictedSpeaker == nil {
        rejectedKnown += 1
      } else {
        wrongKnown += 1
      }
    } else {
      unknownTrials += 1
      if predictedSpeaker == nil {
        rejectedUnknown += 1
      } else {
        acceptedUnknown += 1
      }
    }
  }

  private func ratio(_ numerator: Int, _ denominator: Int) -> Double {
    guard denominator > 0 else {
      return 0
    }
    return Double(numerator) / Double(denominator)
  }
}

// MARK: - LegacyState

private struct LegacyState {
  struct Profile {
    let speakerID: String
    var embedding: [Float]
    var sampleCount: Int
  }

  var profiles: [String: Profile] = [:]
  var learning = SpeakerProfileBenchmarkLearningSummary(
    created: 0,
    addedCoverage: 0,
    duplicate: 0,
    pending: 0
  )

  mutating func learn(_ observation: SpeakerProfileBenchmarkObservation) {
    guard let normalizedEmbedding = normalized(observation.embedding) else {
      return
    }
    guard var profile = profiles[observation.speakerID] else {
      profiles[observation.speakerID] = Profile(
        speakerID: observation.speakerID,
        embedding: normalizedEmbedding,
        sampleCount: 1
      )
      learning = SpeakerProfileBenchmarkLearningSummary(
        created: learning.created + 1,
        addedCoverage: learning.addedCoverage,
        duplicate: learning.duplicate,
        pending: learning.pending
      )
      return
    }

    let count = max(profile.sampleCount, 1)
    let merged = zip(profile.embedding, normalizedEmbedding).map { oldValue, newValue in
      (oldValue * Float(count) + newValue) / Float(count + 1)
    }
    profile.embedding = normalized(merged) ?? merged
    profile.sampleCount = count + 1
    profiles[observation.speakerID] = profile
    learning = SpeakerProfileBenchmarkLearningSummary(
      created: learning.created,
      addedCoverage: learning.addedCoverage + 1,
      duplicate: learning.duplicate,
      pending: learning.pending
    )
  }

  func match(
    queryEmbeddings: [[Float]],
    threshold: Float,
    margin: Float
  ) -> String? {
    let ranked = profiles.values
      .compactMap { profile -> (String, Float)? in
        let similarity = queryEmbeddings
          .compactMap {
            SpeakerProfileMatcher.cosineSimilarity($0, profile.embedding)
          }
          .max()
        return similarity.map { (profile.speakerID, $0) }
      }
      .sorted {
        if $0.1 == $1.1 {
          return $0.0 < $1.0
        }
        return $0.1 > $1.1
      }
    guard let best = ranked.first else {
      return nil
    }
    let separation = ranked.dropFirst().first.map { best.1 - $0.1 } ?? .infinity
    guard best.1 >= threshold, separation >= margin else {
      return nil
    }
    return best.0
  }

  func result(metrics: SpeakerProfileBenchmarkMetrics) -> SpeakerProfileBenchmarkAlgorithmResult {
    SpeakerProfileBenchmarkAlgorithmResult(
      metrics: metrics,
      learning: learning,
      finalProfiles: profiles.count,
      finalActiveSamples: profiles.count,
      finalPendingSamples: 0
    )
  }
}

// MARK: - RepresentativeState

private struct RepresentativeState {
  var profiles: [SpeakerProfile] = []
  var learning = SpeakerProfileBenchmarkLearningSummary(
    created: 0,
    addedCoverage: 0,
    duplicate: 0,
    pending: 0
  )

  mutating func learn(_ observation: SpeakerProfileBenchmarkObservation) {
    let linkedProfileID = profiles.first {
      $0.name.caseInsensitiveCompare(observation.speakerID) == .orderedSame
    }?.id
    guard let result = SpeakerProfileMatcher.learn(
      name: observation.speakerID,
      embedding: observation.embedding,
      linkedProfileID: linkedProfileID,
      profiles: &profiles,
      source: observation.mode == .enrollment ? .voiceRecording : .confirmedRecording,
      sourceRecordingID: observation.meetingID,
      sourceSpeakerID: observation.speakerID
    ) else {
      return
    }

    learning = SpeakerProfileBenchmarkLearningSummary(
      created: learning.created + (result.outcome == .created ? 1 : 0),
      addedCoverage: learning.addedCoverage + (result.outcome == .addedCoverage ? 1 : 0),
      duplicate: learning.duplicate + (result.outcome == .duplicate ? 1 : 0),
      pending: learning.pending + (result.outcome == .pending ? 1 : 0)
    )
  }

  func match(
    queryEmbeddings: [[Float]],
    threshold: Float,
    margin: Float
  ) -> String? {
    SpeakerProfileMatcher.matches(
      speakerEmbeddingCandidates: ["query": queryEmbeddings],
      profiles: profiles,
      minimumSimilarity: threshold,
      minimumMargin: margin
    )["query"]?.name
  }

  func result(metrics: SpeakerProfileBenchmarkMetrics) -> SpeakerProfileBenchmarkAlgorithmResult {
    SpeakerProfileBenchmarkAlgorithmResult(
      metrics: metrics,
      learning: learning,
      finalProfiles: profiles.count,
      finalActiveSamples: profiles.reduce(0) { $0 + $1.voiceSamples.count },
      finalPendingSamples: profiles.reduce(0) { $0 + $1.pendingVoiceSamples.count }
    )
  }
}

private func normalized(_ embedding: [Float]) -> [Float]? {
  guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else {
    return nil
  }
  let magnitude = sqrt(embedding.reduce(into: Float.zero) { $0 += $1 * $1 })
  guard magnitude > 0 else {
    return nil
  }
  return embedding.map { $0 / magnitude }
}
