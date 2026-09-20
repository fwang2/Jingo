import ComposableArchitecture
import Foundation

// MARK: - Transcription

public struct Transcription: Codable, Hashable, Identifiable {
  public let id: UUID
  public var fileName: String
  public var startDate: Date = .init()
  public var segments: [Segment] = []
  public var parameters: TranscriptionParameters
  public var model: String
  public var status: Status = .notStarted
  public var text: String
  public var timings: Timings
  public var speakerEmbeddings: [String: [Float]]
  public var speakerProfileIDs: [String: UUID]
  public var speakerNames: [String: String]

  public var progress: Double {
    if case let .progress(progress, _) = status {
      return progress
    } else if case let .paused(_, progress: progress) = status {
      return progress
    } else if case .done = status {
      return 1
    }

    return 0
  }

  public init(
    id: UUID = UUID(),
    fileName: String,
    startDate: Date = .init(),
    segments: [Segment] = [],
    parameters: TranscriptionParameters,
    model: String,
    status: Status = .notStarted,
    text: String = "",
    timings: Timings = .init(),
    speakerEmbeddings: [String: [Float]] = [:],
    speakerProfileIDs: [String: UUID] = [:],
    speakerNames: [String: String] = [:]
  ) {
    self.id = id
    self.fileName = fileName
    self.startDate = startDate
    self.segments = segments
    self.parameters = parameters
    self.model = model
    self.status = status
    self.text = text
    self.timings = timings
    self.speakerEmbeddings = speakerEmbeddings
    self.speakerProfileIDs = speakerProfileIDs
    self.speakerNames = speakerNames
  }

  private enum CodingKeys: String, CodingKey {
    case id, fileName, startDate, segments, parameters, model, status, text, timings
    case speakerEmbeddings, speakerProfileIDs, speakerNames
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    fileName = try container.decode(String.self, forKey: .fileName)
    startDate = try container.decodeIfPresent(Date.self, forKey: .startDate) ?? Date()
    segments = try container.decodeIfPresent([Segment].self, forKey: .segments) ?? []
    parameters = try container.decode(TranscriptionParameters.self, forKey: .parameters)
    model = try container.decode(String.self, forKey: .model)
    status = try container.decodeIfPresent(Status.self, forKey: .status) ?? .notStarted
    text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
    timings = try container.decodeIfPresent(Timings.self, forKey: .timings) ?? .init()
    speakerEmbeddings = try container.decodeIfPresent(
      [String: [Float]].self,
      forKey: .speakerEmbeddings
    ) ?? [:]
    speakerProfileIDs = try container.decodeIfPresent(
      [String: UUID].self,
      forKey: .speakerProfileIDs
    ) ?? [:]
    speakerNames = try container.decodeIfPresent(
      [String: String].self,
      forKey: .speakerNames
    ) ?? [:]
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(fileName, forKey: .fileName)
    try container.encode(startDate, forKey: .startDate)
    try container.encode(segments, forKey: .segments)
    try container.encode(parameters, forKey: .parameters)
    try container.encode(model, forKey: .model)
    try container.encode(status, forKey: .status)
    try container.encode(text, forKey: .text)
    try container.encode(timings, forKey: .timings)
    if !speakerEmbeddings.isEmpty {
      try container.encode(speakerEmbeddings, forKey: .speakerEmbeddings)
    }
    if !speakerProfileIDs.isEmpty {
      try container.encode(speakerProfileIDs, forKey: .speakerProfileIDs)
    }
    if !speakerNames.isEmpty {
      try container.encode(speakerNames, forKey: .speakerNames)
    }
  }
}

// MARK: Transcription.Timings

public extension Transcription {
  struct Timings: Codable, Hashable {
    public var tokensPerSecond: Double = 0
    public var fullPipeline: TimeInterval = 0

    public init(tokensPerSecond: Double = 0, fullPipeline: TimeInterval = 0) {
      self.tokensPerSecond = tokensPerSecond
      self.fullPipeline = fullPipeline
    }
  }
}

// MARK: Transcription.Status

public extension Transcription {
  @CasePathable
  enum Status: Codable, Hashable {
    case notStarted
    case loading
    case uploading(Double)
    case error(message: String)
    case progress(Double, text: String)
    case done(Date)
    case canceled
    case paused(TranscriptionTask, progress: Double)
  }
}

// MARK: - Segment

public struct Segment: Codable, Hashable, Identifiable, Sendable {
  public var id: Int64 {
    startTimeMS
  }

  public let startTimeMS: Int64
  public let endTimeMS: Int64
  public let text: String
  public let tokens: [Token]
  public let speaker: String?
  public let words: [WordData]

  public init(
    startTimeMS: Int64,
    endTimeMS: Int64,
    text: String,
    tokens: [Token],
    speaker: String? = nil,
    words: [WordData] = []
  ) {
    self.startTimeMS = startTimeMS
    self.endTimeMS = endTimeMS
    self.text = text
    self.tokens = tokens
    self.speaker = speaker
    self.words = words
  }
}

// MARK: - Token

public struct Token: Codable, Hashable, Identifiable, Sendable {
  public let id: Int
  public let index: Int
  public let logProbability: Float
  public let speaker: String?

  public init(
    id: Int,
    index: Int,
    logProbability: Float,
    speaker: String? = nil
  ) {
    self.id = id
    self.index = index
    self.logProbability = logProbability
    self.speaker = speaker
  }
}

// MARK: - WordData

public struct WordData: Codable, Hashable, Sendable {
  public let word: String
  public let startTimeMS: Int64
  public let endTimeMS: Int64
  public let probability: Double

  public init(
    word: String,
    startTimeMS: Int64,
    endTimeMS: Int64,
    probability: Double
  ) {
    self.word = word
    self.startTimeMS = startTimeMS
    self.endTimeMS = endTimeMS
    self.probability = probability
  }
}

public extension Transcription.Status {
  var isDone: Bool {
    switch self {
    case .done:
      true

    default:
      false
    }
  }

  var isNotStarted: Bool {
    switch self {
    case .notStarted:
      true

    default:
      false
    }
  }

  var isLoading: Bool {
    switch self {
    case .loading:
      true

    default:
      false
    }
  }

  var isUploading: Bool {
    switch self {
    case .uploading:
      true

    default:
      false
    }
  }

  var isCanceled: Bool {
    switch self {
    case .canceled:
      true

    default:
      false
    }
  }

  var isProgress: Bool {
    switch self {
    case .progress:
      true

    default:
      false
    }
  }

  var isError: Bool {
    switch self {
    case .error:
      true

    default:
      false
    }
  }

  var uploadProgress: Double? {
    switch self {
    case let .uploading(progress):
      progress

    default:
      nil
    }
  }

  var progressValue: Double? {
    switch self {
    case let .progress(progress, _):
      progress

    default:
      nil
    }
  }

  var errorMessage: String? {
    switch self {
    case let .error(message: message):
      message

    default:
      nil
    }
  }

  var isLoadingOrProgress: Bool {
    switch self {
    case .loading, .progress, .uploading:
      true

    default:
      false
    }
  }

  var isErrorOrCanceled: Bool {
    switch self {
    case .canceled, .error:
      true

    default:
      false
    }
  }

  var isPaused: Bool {
    switch self {
    case .paused:
      true

    default:
      false
    }
  }
}

#if DEBUG
  public extension Transcription {
    static let mock1 = Transcription(
      id: UUID(),
      fileName: "test1",
      startDate: Date(),
      segments: [
        Segment(
          startTimeMS: 0,
          endTimeMS: 0,
          text: "This is a random sentence.",
          tokens: [
            Token(
              id: 0,
              index: 0,
              logProbability: 0.1,
              speaker: nil
            ),
          ],
          speaker: nil
        ),
      ],
      parameters: TranscriptionParameters(),
      model: "tiny",
      status: .done(Date()),
      timings: Timings(tokensPerSecond: 1, fullPipeline: 1)
    )

    static let mock2 = Transcription(
      id: UUID(),
      fileName: "test2",
      startDate: Date(),
      segments: [
        Segment(
          startTimeMS: 0,
          endTimeMS: 0,
          text: "This is another random sentence. Here is a second sentence.",
          tokens: [
            Token(
              id: 0,
              index: 0,
              logProbability: 0.1,
              speaker: nil
            ),
          ],
          speaker: nil
        ),
      ],
      parameters: TranscriptionParameters(),
      model: "tiny",
      status: .done(Date()),
      timings: Timings(tokensPerSecond: 1, fullPipeline: 1)
    )

    static let mock3 = Transcription(
      id: UUID(),
      fileName: "test3",
      startDate: Date(),
      segments: [
        Segment(
          startTimeMS: 0,
          endTimeMS: 0,
          text: "Here is a random sentence. This is a second sentence. And a third one.",
          tokens: [
            Token(
              id: 0,
              index: 0,
              logProbability: 0.1,
              speaker: nil
            ),
          ],
          speaker: nil
        ),
      ],
      parameters: TranscriptionParameters(),
      model: "tiny",
      status: .done(Date()),
      timings: Timings(tokensPerSecond: 1, fullPipeline: 1)
    )
  }
#endif
