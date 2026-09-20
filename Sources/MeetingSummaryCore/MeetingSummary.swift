import Foundation

// MARK: - MeetingSummary

public struct MeetingSummary: Codable, Hashable, Sendable {
  public enum Status: Codable, Hashable, Sendable {
    case queued
    case generating
    case completed
    case failed(message: String)
  }

  public struct ActionItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String {
      [task, owner ?? "", dueDate ?? ""].joined(separator: "|")
    }

    public let task: String
    public let owner: String?
    public let dueDate: String?
    public let sourceTurnIDs: [String]

    public init(
      task: String,
      owner: String? = nil,
      dueDate: String? = nil,
      sourceTurnIDs: [String] = []
    ) {
      self.task = task
      self.owner = owner
      self.dueDate = dueDate
      self.sourceTurnIDs = sourceTurnIDs
    }
  }

  public struct Highlight: Codable, Hashable, Sendable, Identifiable {
    public var id: String {
      [text, sourceTurnIDs.joined(separator: ",")].joined(separator: "|")
    }

    public let text: String
    public let sourceTurnIDs: [String]

    public init(text: String, sourceTurnIDs: [String] = []) {
      self.text = text
      self.sourceTurnIDs = sourceTurnIDs
    }
  }

  public var status: Status
  public var overview: String
  public var keyPoints: [String]
  public var decisions: [String]
  public var openItems: [String]
  public var participantContributions: [String]
  public var actionItems: [ActionItem]
  public var risksAndFollowUpQuestions: [String]
  public var highlights: [Highlight]
  public var meetingStatus: String
  public var generatedAt: Date?
  public var model: String
  public var sourceFingerprint: String
  public var promptVersion: Int

  public init(
    status: Status,
    overview: String = "",
    keyPoints: [String] = [],
    decisions: [String] = [],
    openItems: [String] = [],
    participantContributions: [String] = [],
    actionItems: [ActionItem] = [],
    risksAndFollowUpQuestions: [String] = [],
    highlights: [Highlight] = [],
    meetingStatus: String = "",
    generatedAt: Date? = nil,
    model: String,
    sourceFingerprint: String,
    promptVersion: Int = 1
  ) {
    self.status = status
    self.overview = overview
    self.keyPoints = keyPoints
    self.decisions = decisions
    self.openItems = openItems
    self.participantContributions = participantContributions
    self.actionItems = actionItems
    self.risksAndFollowUpQuestions = risksAndFollowUpQuestions
    self.highlights = highlights
    self.meetingStatus = meetingStatus
    self.generatedAt = generatedAt
    self.model = model
    self.sourceFingerprint = sourceFingerprint
    self.promptVersion = promptVersion
  }

  public static func fingerprint(for transcript: String) -> String {
    // FNV-1a is deterministic across launches and sufficient for stale-summary detection.
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in transcript.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }

  public func limited(to budget: MeetingSummaryLengthBudget) -> MeetingSummary {
    var remainingItems = budget.totalDetailLimit

    let keptActionItems = Array(actionItems.prefix(min(budget.actionItemLimit, remainingItems)))
    remainingItems -= keptActionItems.count

    let keptDecisions = Array(decisions.prefix(min(budget.decisionLimit, remainingItems)))
    remainingItems -= keptDecisions.count

    let keptOpenItems = Array(openItems.prefix(min(budget.openItemLimit, remainingItems)))
    remainingItems -= keptOpenItems.count

    let keptRisks = Array(
      risksAndFollowUpQuestions.prefix(min(budget.riskOrQuestionLimit, remainingItems))
    )
    remainingItems -= keptRisks.count

    let keptKeyPoints = Array(keyPoints.prefix(min(budget.keyPointLimit, remainingItems)))
    remainingItems -= keptKeyPoints.count

    let keptContributions = Array(
      participantContributions.prefix(
        min(budget.participantContributionLimit, remainingItems)
      )
    )
    remainingItems -= keptContributions.count

    let keptHighlights = Array(highlights.prefix(min(budget.highlightLimit, remainingItems)))

    return MeetingSummary(
      status: status,
      overview: overview.limited(
        toWords: budget.overviewWordLimit,
        characters: budget.overviewCharacterLimit
      ),
      keyPoints: keptKeyPoints,
      decisions: keptDecisions,
      openItems: keptOpenItems,
      participantContributions: keptContributions,
      actionItems: keptActionItems,
      risksAndFollowUpQuestions: keptRisks,
      highlights: keptHighlights,
      meetingStatus: meetingStatus.limited(
        toWords: budget.meetingStatusWordLimit,
        characters: budget.meetingStatusCharacterLimit
      ),
      generatedAt: generatedAt,
      model: model,
      sourceFingerprint: sourceFingerprint,
      promptVersion: promptVersion
    )
  }

  private enum CodingKeys: String, CodingKey {
    case status
    case overview
    case keyPoints
    case decisions
    case openItems
    case participantContributions
    case actionItems
    case risksAndFollowUpQuestions
    case highlights
    case meetingStatus
    case generatedAt
    case model
    case sourceFingerprint
    case promptVersion
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decode(Status.self, forKey: .status)
    overview = try container.decodeIfPresent(String.self, forKey: .overview) ?? ""
    keyPoints = try container.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
    decisions = try container.decodeIfPresent([String].self, forKey: .decisions) ?? []
    openItems = try container.decodeIfPresent([String].self, forKey: .openItems) ?? []
    participantContributions = try container.decodeIfPresent(
      [String].self,
      forKey: .participantContributions
    ) ?? []
    actionItems = try container.decodeIfPresent([ActionItem].self, forKey: .actionItems) ?? []
    risksAndFollowUpQuestions = try container.decodeIfPresent(
      [String].self,
      forKey: .risksAndFollowUpQuestions
    ) ?? []
    highlights = try container.decodeIfPresent([Highlight].self, forKey: .highlights) ?? []
    meetingStatus = try container.decodeIfPresent(String.self, forKey: .meetingStatus) ?? ""
    generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt)
    model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
    sourceFingerprint = try container.decodeIfPresent(
      String.self,
      forKey: .sourceFingerprint
    ) ?? ""
    promptVersion = try container.decodeIfPresent(Int.self, forKey: .promptVersion) ?? 1
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(status, forKey: .status)
    try container.encode(overview, forKey: .overview)
    try container.encode(keyPoints, forKey: .keyPoints)
    try container.encode(decisions, forKey: .decisions)
    try container.encode(openItems, forKey: .openItems)
    try container.encode(participantContributions, forKey: .participantContributions)
    try container.encode(actionItems, forKey: .actionItems)
    try container.encode(risksAndFollowUpQuestions, forKey: .risksAndFollowUpQuestions)
    try container.encode(highlights, forKey: .highlights)
    try container.encode(meetingStatus, forKey: .meetingStatus)
    try container.encodeIfPresent(generatedAt, forKey: .generatedAt)
    try container.encode(model, forKey: .model)
    try container.encode(sourceFingerprint, forKey: .sourceFingerprint)
    try container.encode(promptVersion, forKey: .promptVersion)
  }
}

// MARK: - MeetingSummaryLengthBudget

public struct MeetingSummaryLengthBudget: Equatable, Sendable {
  public let overviewWordLimit: Int
  public let overviewCharacterLimit: Int
  public let keyPointLimit: Int
  public let decisionLimit: Int
  public let openItemLimit: Int
  public let participantContributionLimit: Int
  public let actionItemLimit: Int
  public let riskOrQuestionLimit: Int
  public let highlightLimit: Int
  public let totalDetailLimit: Int
  public let meetingStatusWordLimit: Int
  public let meetingStatusCharacterLimit: Int

  public static func calibrated(
    duration: TimeInterval,
    transcript: String
  ) -> MeetingSummaryLengthBudget {
    let wordCount = transcript.split(whereSeparator: { $0.isWhitespace }).count
    let contentMinutes = Double(wordCount) / 150
    let effectiveMinutes = max(max(duration, 0) / 60, contentMinutes)

    switch effectiveMinutes {
    case ..<2:
      return MeetingSummaryLengthBudget(
        overviewWordLimit: 35,
        overviewCharacterLimit: 220,
        keyPointLimit: 2,
        decisionLimit: 1,
        openItemLimit: 1,
        participantContributionLimit: 1,
        actionItemLimit: 1,
        riskOrQuestionLimit: 1,
        highlightLimit: 0,
        totalDetailLimit: 3,
        meetingStatusWordLimit: 20,
        meetingStatusCharacterLimit: 160
      )
    case ..<15:
      return MeetingSummaryLengthBudget(
        overviewWordLimit: 90,
        overviewCharacterLimit: 600,
        keyPointLimit: 6,
        decisionLimit: 4,
        openItemLimit: 4,
        participantContributionLimit: 4,
        actionItemLimit: 6,
        riskOrQuestionLimit: 4,
        highlightLimit: 4,
        totalDetailLimit: 14,
        meetingStatusWordLimit: 25,
        meetingStatusCharacterLimit: 200
      )
    case ..<45:
      return MeetingSummaryLengthBudget(
        overviewWordLimit: 150,
        overviewCharacterLimit: 1000,
        keyPointLimit: 10,
        decisionLimit: 8,
        openItemLimit: 8,
        participantContributionLimit: 8,
        actionItemLimit: 10,
        riskOrQuestionLimit: 8,
        highlightLimit: 6,
        totalDetailLimit: 26,
        meetingStatusWordLimit: 30,
        meetingStatusCharacterLimit: 240
      )
    default:
      return MeetingSummaryLengthBudget(
        overviewWordLimit: 220,
        overviewCharacterLimit: 1500,
        keyPointLimit: 16,
        decisionLimit: 12,
        openItemLimit: 12,
        participantContributionLimit: 12,
        actionItemLimit: 16,
        riskOrQuestionLimit: 12,
        highlightLimit: 10,
        totalDetailLimit: 42,
        meetingStatusWordLimit: 35,
        meetingStatusCharacterLimit: 280
      )
    }
  }
}

private extension String {
  func limited(toWords wordLimit: Int, characters characterLimit: Int) -> String {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    let words = trimmed.split(whereSeparator: { $0.isWhitespace })
    let wordLimited = words.count > wordLimit
      ? words.prefix(wordLimit).joined(separator: " ") + "…"
      : trimmed
    guard wordLimited.count > characterLimit else {
      return wordLimited
    }
    return String(wordLimited.prefix(max(0, characterLimit - 1)))
      .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
  }
}
