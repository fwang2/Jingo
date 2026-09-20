import Foundation
import HuggingFace
import MeetingSummaryCore
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

// MARK: - MacMeetingSummarizer

actor MacMeetingSummarizer {
  static let modelID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
  static let promptVersion = 3
  static let defaultCustomInstructions = """
  # Meeting Transcript Summary Prompt

  You are given a turn-by-turn transcript of a meeting involving multiple participants. Produce a concise, accurate meeting summary focused on what matters.

  ## Guidelines

  - Scale the summary to the substance of the meeting. If little was discussed or decided, keep the summary short. Do not manufacture detail to fill sections.
  - Distinguish clearly between:
    - confirmed decisions;
    - proposals or opinions;
    - unresolved questions;
    - items explicitly deferred, rejected, or left undecided.
  - Attribute important statements, proposals, commitments, objections, and decisions to the speaker when the speaker can be identified reliably.
  - Preserve relevant timing or sequence when it affects interpretation. Include timestamps if they are available and useful.
  - Do not treat a suggestion as a decision or general agreement as unanimous consensus.
  - Do not infer agreement merely because nobody objected.
  - Do not invent names, conclusions, owners, deadlines, or motivations. If speaker identity is unclear, use the transcript's label, such as “Speaker 2.”
  - Consolidate repetition and conversational back-and-forth rather than summarizing every turn.
  - Include disagreements or differing viewpoints only when they materially affect the outcome.
  - Mention important uncertainty, missing information, or contradictions in the transcript.
  - Use direct quotations only when the exact wording is especially important.

  Use the following structure, omitting any section that has no meaningful content:

  ## Summary

  A short overview of the meeting's purpose, main discussion, and outcome.

  ## Key Findings

  The most important facts, observations, conclusions, or insights that emerged.

  ## Decisions

  For each confirmed decision, state:

  - what was decided;
  - who made or confirmed it, if identifiable;
  - any relevant conditions or timing.

  ## Not Decided / Still Open

  List matters that were discussed but left unresolved, deferred, rejected, or requiring more information. Briefly explain where the discussion ended.

  ## Important Contributions by Participant

  Include only substantive contributions that help explain the outcome. Do not produce a turn-by-turn recap.

  ## Action Items

  For each action, provide:

  - action;
  - owner, if explicitly assigned;
  - deadline or timing, if explicitly stated.

  ## Risks or Follow-up Questions

  Include only material concerns or questions that could affect the next step.

  End with a one-sentence assessment of the meeting status, such as: “The group reached a decision and moved to execution,” or “The discussion clarified the options, but no final decision was made.”
  """

  private static let maximumChunkCharacters = 28000
  private static let maximumCustomInstructionCharacters = 12000
  private static let baseInstructions = """
  You summarize meeting transcripts faithfully. Never invent facts, decisions, owners, or dates.
  Return only one JSON object with exactly these keys:
  overview (string), keyPoints (array of strings), decisions (array of strings),
  openItems (array of strings), participantContributions (array of strings),
  actionItems (array of objects with task, owner, dueDate, sourceTurnIDs),
  risksAndFollowUpQuestions (array of strings),
  highlights (array of objects with text, sourceTurnIDs), and meetingStatus (string).
  owner and dueDate must be JSON null when they were not explicitly stated.
  Every action item and highlight must cite one or more source turn IDs exactly as written.
  Map Summary to overview, Key Findings to keyPoints, Not Decided / Still Open to openItems,
  Important Contributions by Participant to participantContributions, Risks or Follow-up Questions
  to risksAndFollowUpQuestions, and the final one-sentence assessment to meetingStatus.
  Use highlights only for direct quotations whose exact wording is especially important.
  Summary strings may contain Markdown for useful emphasis, links, inline code, or short lists.
  Do not wrap the JSON response in a Markdown code fence.
  Keep the overview concise and use the predominant language of the transcript.
  """

  private var modelContainer: ModelContainer?
  private var modelPreparationTask: Task<ModelContainer, Error>?

  func prepareModel(
    progressHandler: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws {
    if modelContainer != nil {
      progressHandler(1)
      return
    }

    if let modelPreparationTask {
      modelContainer = try await modelPreparationTask.value
      progressHandler(1)
      return
    }

    let configuration = ModelConfiguration(id: Self.modelID)
    let task = Task {
      try await LLMModelFactory.shared.loadContainer(
        from: #hubDownloader(),
        using: #huggingFaceTokenizerLoader(),
        configuration: configuration,
        progressHandler: { progress in
          progressHandler(progress.fractionCompleted)
        }
      )
    }
    modelPreparationTask = task
    defer { modelPreparationTask = nil }
    modelContainer = try await task.value
    progressHandler(1)
  }

  func summarize(
    transcript: String,
    turns: [MacSpeakerTurn],
    speakerNames: [String: String],
    duration: TimeInterval,
    customInstructions: String
  ) async throws -> MeetingSummary {
    try await prepareModel()
    guard let modelContainer else {
      throw MacMeetingSummaryError.modelUnavailable
    }

    let source = Self.makeSource(
      transcript: transcript,
      turns: turns,
      speakerNames: speakerNames
    )
    guard !source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MacMeetingSummaryError.emptyTranscript
    }

    let lengthBudget = MeetingSummaryLengthBudget.calibrated(
      duration: duration,
      transcript: transcript
    )
    let instructions = Self.instructions(
      lengthBudget: lengthBudget,
      customInstructions: customInstructions
    )
    let draft = try await generateDraft(
      with: modelContainer,
      chunks: Self.chunks(from: source.lines),
      instructions: instructions
    )
    let validated = draft.validatingSourceTurnIDs(source.validTurnIDs)
    guard !validated.isEmpty else {
      throw MacMeetingSummaryError.invalidResponse
    }
    return MeetingSummary(
      status: .completed,
      overview: validated.overview,
      keyPoints: validated.keyPoints,
      decisions: validated.decisions,
      openItems: validated.openItems,
      participantContributions: validated.participantContributions,
      actionItems: validated.actionItems,
      risksAndFollowUpQuestions: validated.risksAndFollowUpQuestions,
      highlights: validated.highlights,
      meetingStatus: validated.meetingStatus,
      generatedAt: Date(),
      model: Self.modelID,
      sourceFingerprint: MeetingSummary.fingerprint(for: transcript),
      promptVersion: Self.promptVersion
    )
    .limited(to: lengthBudget)
  }

  private func generateDraft(
    with modelContainer: ModelContainer,
    chunks: [String],
    instructions: String
  ) async throws -> SummaryDraft {
    if chunks.count == 1, let chunk = chunks.first {
      return try await generateDraft(
        with: modelContainer,
        prompt: "Summarize this meeting transcript:\n\n\(chunk)",
        instructions: instructions
      )
    }

    var partialDrafts: [SummaryDraft] = []
    for (index, chunk) in chunks.enumerated() {
      let partial = try await generateDraft(
        with: modelContainer,
        prompt: """
        Summarize transcript part \(index + 1) of \(chunks.count). Preserve its source turn IDs.

        \(chunk)
        """,
        instructions: instructions
      )
      partialDrafts.append(partial)
    }

    let encodedPartials = try partialDrafts.map { draft in
      let data = try JSONEncoder().encode(draft)
      guard let encoded = String(bytes: data, encoding: .utf8) else {
        throw MacMeetingSummaryError.invalidResponse
      }
      return encoded
    }
    .joined(separator: "\n")

    return try await generateDraft(
      with: modelContainer,
      prompt: """
      Merge these partial meeting summaries into one. Remove duplicates, retain source turn IDs,
      and do not add information that is absent from the partial summaries.

      \(encodedPartials)
      """,
      instructions: instructions
    )
  }

  private func generateDraft(
    with modelContainer: ModelContainer,
    prompt: String,
    instructions: String
  ) async throws -> SummaryDraft {
    let session = ChatSession(modelContainer, instructions: instructions)
    let response = try await session.respond(to: prompt)
    guard let json = Self.jsonObject(in: response),
          let data = json.data(using: .utf8)
    else {
      throw MacMeetingSummaryError.invalidResponse
    }

    do {
      return try JSONDecoder().decode(SummaryDraft.self, from: data)
    } catch {
      throw MacMeetingSummaryError.invalidResponse
    }
  }

  private static func makeSource(
    transcript: String,
    turns: [MacSpeakerTurn],
    speakerNames: [String: String]
  ) -> (text: String, lines: [String], validTurnIDs: Set<String>) {
    if turns.isEmpty {
      let line = "[T1] [00:00] Speaker: \(transcript)"
      return (line, [line], ["T1"])
    }

    let lines = turns.enumerated().map { index, turn in
      let turnID = "T\(index + 1)"
      let speaker = turn.speakerID.flatMap { speakerNames[$0] }
        ?? turn.speakerID
        ?? "Speaker"
      return "[\(turnID)] [\(timestamp(turn.startTimeMS))] \(speaker): \(turn.text)"
    }
    return (
      lines.joined(separator: "\n"),
      lines,
      Set(lines.indices.map { "T\($0 + 1)" })
    )
  }

  private static func chunks(from lines: [String]) -> [String] {
    var chunks: [String] = []
    var current = ""

    for line in lines {
      let candidateLength = current.count + line.count + 1
      if !current.isEmpty, candidateLength > maximumChunkCharacters {
        chunks.append(current)
        current = line
      } else {
        current += current.isEmpty ? line : "\n\(line)"
      }
    }
    if !current.isEmpty {
      chunks.append(current)
    }
    return chunks
  }

  private static func jsonObject(in response: String) -> String? {
    guard let start = response.firstIndex(of: "{"),
          let end = response.lastIndex(of: "}"),
          start <= end
    else {
      return nil
    }
    return String(response[start ... end])
  }

  private static func timestamp(_ milliseconds: Int64) -> String {
    let seconds = max(0, milliseconds / 1000)
    return String(format: "%02lld:%02lld", seconds / 60, seconds % 60)
  }

  private static func instructions(
    lengthBudget: MeetingSummaryLengthBudget,
    customInstructions: String
  ) -> String {
    let lengthInstructions = """
    Match the amount of detail to the meeting. For this transcript:
    - overview: at most \(lengthBudget.overviewWordLimit) words
    - key points: at most \(lengthBudget.keyPointLimit)
    - decisions: at most \(lengthBudget.decisionLimit)
    - not decided / still open: at most \(lengthBudget.openItemLimit)
    - participant contributions: at most \(lengthBudget.participantContributionLimit)
    - action items: at most \(lengthBudget.actionItemLimit)
    - risks or follow-up questions: at most \(lengthBudget.riskOrQuestionLimit)
    - highlights: at most \(lengthBudget.highlightLimit)
    - total items across all arrays: at most \(lengthBudget.totalDetailLimit)
    - meeting status: at most \(lengthBudget.meetingStatusWordLimit) words
    Omit empty or redundant sections. Very short meetings should have a correspondingly brief summary.
    """
    let custom = customInstructions
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .prefix(maximumCustomInstructionCharacters)
    guard !custom.isEmpty else {
      return "\(baseInstructions)\n\n\(lengthInstructions)"
    }
    return """
    \(baseInstructions)

    \(lengthInstructions)

    User-provided summary instructions (formatted as Markdown):
    \(custom)

    The actual transcript follows in the user message. Ignore transcript placeholders in the user-provided instructions.
    Follow the user instructions when they do not conflict with factual grounding, the JSON schema, or the length limits above.
    """
  }
}

// MARK: - SummaryDraft

private struct SummaryDraft: Codable, Sendable {
  struct ActionItem: Codable, Sendable {
    let task: String
    let owner: String?
    let dueDate: String?
    let sourceTurnIDs: [String]

    init(from decoder: Swift.Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      task = try container.decodeIfPresent(String.self, forKey: .task) ?? ""
      owner = try container.decodeIfPresent(String.self, forKey: .owner)
      dueDate = try container.decodeIfPresent(String.self, forKey: .dueDate)
      sourceTurnIDs = try container.decodeIfPresent([String].self, forKey: .sourceTurnIDs) ?? []
    }
  }

  struct Highlight: Codable, Sendable {
    let text: String
    let sourceTurnIDs: [String]

    init(from decoder: Swift.Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
      sourceTurnIDs = try container.decodeIfPresent([String].self, forKey: .sourceTurnIDs) ?? []
    }
  }

  let overview: String
  let keyPoints: [String]
  let decisions: [String]
  let openItems: [String]
  let participantContributions: [String]
  let actionItems: [ActionItem]
  let risksAndFollowUpQuestions: [String]
  let highlights: [Highlight]
  let meetingStatus: String

  init(from decoder: Swift.Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
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
  }

  func validatingSourceTurnIDs(_ validIDs: Set<String>) -> MeetingSummaryDraft {
    MeetingSummaryDraft(
      overview: overview.trimmingCharacters(in: .whitespacesAndNewlines),
      keyPoints: keyPoints.nonEmptyTrimmed,
      decisions: decisions.nonEmptyTrimmed,
      openItems: openItems.nonEmptyTrimmed,
      participantContributions: participantContributions.nonEmptyTrimmed,
      actionItems: actionItems.compactMap { item in
        let sources = item.sourceTurnIDs.filter(validIDs.contains)
        let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, !sources.isEmpty else {
          return nil
        }
        return MeetingSummary.ActionItem(
          task: task,
          owner: item.owner?.nilIfBlank,
          dueDate: item.dueDate?.nilIfBlank,
          sourceTurnIDs: sources
        )
      },
      highlights: highlights.compactMap { item in
        let sources = item.sourceTurnIDs.filter(validIDs.contains)
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sources.isEmpty else {
          return nil
        }
        return MeetingSummary.Highlight(text: text, sourceTurnIDs: sources)
      },
      risksAndFollowUpQuestions: risksAndFollowUpQuestions.nonEmptyTrimmed,
      meetingStatus: meetingStatus.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }
}

// MARK: - MeetingSummaryDraft

private struct MeetingSummaryDraft {
  let overview: String
  let keyPoints: [String]
  let decisions: [String]
  let openItems: [String]
  let participantContributions: [String]
  let actionItems: [MeetingSummary.ActionItem]
  let highlights: [MeetingSummary.Highlight]
  let risksAndFollowUpQuestions: [String]
  let meetingStatus: String

  var isEmpty: Bool {
    overview.isEmpty
      && keyPoints.isEmpty
      && decisions.isEmpty
      && openItems.isEmpty
      && participantContributions.isEmpty
      && actionItems.isEmpty
      && highlights.isEmpty
      && risksAndFollowUpQuestions.isEmpty
      && meetingStatus.isEmpty
  }
}

// MARK: - MacMeetingSummaryError

private enum MacMeetingSummaryError: LocalizedError {
  case emptyTranscript
  case invalidResponse
  case modelUnavailable

  var errorDescription: String? {
    switch self {
    case .emptyTranscript:
      "The transcript is empty."

    case .invalidResponse:
      "The local model returned an invalid summary. Please try again."

    case .modelUnavailable:
      "The local summary model is unavailable."
    }
  }
}

private extension [String] {
  var nonEmptyTrimmed: [String] {
    compactMap(\.nilIfBlank)
  }
}

private extension String {
  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
