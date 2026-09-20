import Common
import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT

// MARK: - ModelState

public enum ModelState: CustomStringConvertible, Equatable, Sendable {
  case unloaded
  case downloading
  case loading
  case loaded

  public var description: String {
    switch self {
    case .unloaded: "unloaded"
    case .downloading: "downloading"
    case .loading: "loading"
    case .loaded: "loaded"
    }
  }
}

// MARK: - TranscriptionStream

public actor TranscriptionStream {
  public static let sampleRate = 16000
  public static let modelDirURL: URL = .applicationSupportDirectory
    .appendingPathComponent("WhisperBoard/Models", isDirectory: true)

  public struct Progress: Sendable {
    public let text: String

    public init(text: String) {
      self.text = text
    }
  }

  public struct Result: Sendable {
    public struct Timings: Sendable {
      public let tokensPerSecond: Double
      public let fullPipeline: TimeInterval

      public init(tokensPerSecond: Double, fullPipeline: TimeInterval) {
        self.tokensPerSecond = tokensPerSecond
        self.fullPipeline = fullPipeline
      }
    }

    public let text: String
    public let segments: [Segment]
    public let timings: Timings
    public let speakerEmbeddings: [String: [Float]]

    public init(
      text: String,
      segments: [Segment],
      timings: Timings,
      speakerEmbeddings: [String: [Float]] = [:]
    ) {
      self.text = text
      self.segments = segments
      self.timings = timings
      self.speakerEmbeddings = speakerEmbeddings
    }
  }

  public struct State: Sendable {
    public var lastBufferSize = 0
    public var currentText = ""
    public var confirmedSegments: [Segment] = []
    public var unconfirmedSegments: [Segment] = []
    public var tokensPerSecond: Double = 0
    public var isWorking = false

    public var selectedModel = Model.defaultModelName
    public var silenceThreshold: Double = 0.3
    public var useVAD = true

    public var modelState: ModelState = .unloaded
    public var remoteModels: [String] = []
    public var localModels: [String] = []
    public var localModelPath = ""
    public var availableModels: [String] = []
    public var loadingProgressValue: Float = 0
  }

  public var state: State = .init() {
    didSet {
      let copyState = state
      DispatchQueue.main.async { [stateChangeCallback] in
        stateChangeCallback?(copyState)
      }
    }
  }

  public var stateChangeCallback: ((State) -> Void)?

  private let audioProcessor: AudioProcessor
  private var qwenModel: Qwen3ASRModel?
  private var confirmedLiveText = ""
  private var provisionalLiveText = ""
  private var liveAudioSampleCount = 0

  public init(audioProcessor: AudioProcessor) {
    self.audioProcessor = audioProcessor
  }

  func fetchModels() async throws {
    let isLocal = Self.isQwenModelLocal
    state.selectedModel = Model.defaultModelName
    state.availableModels = [Model.qwen3ASR]
    state.remoteModels = isLocal ? [] : [Model.qwen3ASR]
    state.localModels = isLocal ? [Model.qwen3ASR] : []
    state.localModelPath = Self.qwenModelDirectory.path
  }

  func loadModel(
    _: String,
    redownload: Bool = false,
    progressCallback: @escaping @Sendable (Double) -> Void = { _ in }
  ) async throws {
    #if targetEnvironment(simulator)
      throw NSError(
        domain: "TranscriptionStream",
        code: 3,
        userInfo: [
          NSLocalizedDescriptionKey: "Qwen3-ASR requires MLX Metal and cannot run in the iOS Simulator. Use a physical Apple device for live transcription.",
        ]
      )
    #else

      if qwenModel != nil, !redownload {
        state.selectedModel = Model.qwen3ASR
        state.loadingProgressValue = 1
        state.modelState = .loaded
        progressCallback(1)
        return
      }

      state.selectedModel = Model.qwen3ASR
      state.loadingProgressValue = 0
      state.modelState = .downloading
      progressCallback(0)

      if redownload {
        try? FileManager.default.removeItem(at: Self.qwenModelDirectory)
      }

      guard let repository = Repo.ID(rawValue: Model.qwen3ASR) else {
        throw NSError(
          domain: "TranscriptionStream",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Invalid Qwen3-ASR model identifier."]
        )
      }

      let cache = HubCache(cacheDirectory: Self.modelDirURL)
      let client = HubClient(cache: cache)
      let modelDirectory = try await ModelUtils.resolveOrDownloadModel(
        client: client,
        cache: cache,
        repoID: repository,
        requiredExtension: "safetensors",
        progressHandler: { [weak self] progress in
          progressCallback(progress.fractionCompleted)
          Task {
            await self?.updateDownloadProgress(progress.fractionCompleted)
          }
        }
      )
      try? FileManager.default.removeItem(
        at: cache.repoDirectory(repo: repository, kind: .model)
      )

      state.modelState = .loading
      qwenModel = try await Qwen3ASRModel.fromModelDirectory(modelDirectory)
      state.localModels = [Model.qwen3ASR]
      state.remoteModels = []
      state.localModelPath = modelDirectory.path
      state.loadingProgressValue = 1
      state.modelState = .loaded
      progressCallback(1)
    #endif
  }

  public func deleteModel(_: String) async throws {
    unloadModel()
    try? FileManager.default.removeItem(at: Self.modelDirURL)
    state.localModels = []
  }

  public func unloadModel() {
    qwenModel = nil
    Memory.clearCache()
    state.loadingProgressValue = 0
    state.modelState = .unloaded
  }

  public func startRealtimeLoop(callback: @escaping (State) -> Void) async throws {
    guard let qwenModel else {
      throw NSError(
        domain: "TranscriptionStream",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Qwen3-ASR is not loaded."]
      )
    }

    stateChangeCallback = callback
    state.isWorking = true
    confirmedLiveText = ""
    provisionalLiveText = ""
    liveAudioSampleCount = 0

    let session = StreamingInferenceSession(
      model: qwenModel,
      config: Self.streamingConfig
    )
    let feeder = Task { [weak self] in
      try await self?.feedAudio(to: session)
    }
    defer {
      feeder.cancel()
      session.cancel()
      stateChangeCallback = nil
    }

    for await event in session.events {
      try Task.checkCancellation()
      handle(event)
    }
    try await feeder.value
    stateChangeCallback = nil
  }

  public func stopRealtimeLoop() {
    state.isWorking = false
  }

  public func resetState() {
    _ = audioProcessor.drainAudioSamples()
    let modelState: ModelState = qwenModel == nil ? .unloaded : .loaded
    let isLocal = Self.isQwenModelLocal
    state = .init()
    state.modelState = modelState
    state.loadingProgressValue = modelState == .loaded ? 1 : 0
    state.availableModels = [Model.qwen3ASR]
    state.localModels = isLocal ? [Model.qwen3ASR] : []
    state.remoteModels = isLocal ? [] : [Model.qwen3ASR]
    state.localModelPath = Self.qwenModelDirectory.path
    confirmedLiveText = ""
    provisionalLiveText = ""
    liveAudioSampleCount = 0
  }

  public func transcribeAudioFile(
    _ fileURL: URL,
    callback: @escaping (Progress, Double) -> Bool?
  ) async throws -> Result {
    guard let qwenModel else {
      throw NSError(
        domain: "TranscriptionStream",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Qwen3-ASR is not loaded."]
      )
    }

    let audioBuffer = try AudioProcessor.loadAudio(fromPath: fileURL.path)
    let samples = AudioProcessor.convertBufferToArray(buffer: audioBuffer)
    let output = qwenModel.generate(
      audio: MLXArray(samples),
      generationParameters: Self.generationParameters
    )

    _ = callback(Progress(text: output.text), 1)

    let duration = Double(samples.count) / Double(Self.sampleRate)
    let segments = Self.makeSegments(from: output, fallbackDuration: duration)
    return Result(
      text: output.text.trimmingCharacters(in: .whitespacesAndNewlines),
      segments: segments,
      timings: .init(
        tokensPerSecond: output.generationTps,
        fullPipeline: output.totalTime
      )
    )
  }

  private func feedAudio(to session: StreamingInferenceSession) async throws {
    while state.isWorking {
      try Task.checkCancellation()
      let samples = audioProcessor.drainAudioSamples()
      if !samples.isEmpty {
        session.feedAudio(samples: samples)
        liveAudioSampleCount += samples.count
        state.lastBufferSize = liveAudioSampleCount
      }
      try await Task.sleep(for: .milliseconds(100))
    }

    let finalSamples = audioProcessor.drainAudioSamples()
    if !finalSamples.isEmpty {
      session.feedAudio(samples: finalSamples)
      liveAudioSampleCount += finalSamples.count
    }
    session.stop()
  }

  private func handle(_ event: TranscriptionEvent) {
    switch event {
    case let .provisional(text):
      provisionalLiveText = QwenStreamingTextCleaner.clean(text)
      updateLiveSegments()

    case let .confirmed(text):
      confirmedLiveText = QwenStreamingTextCleaner.clean(text)
      updateLiveSegments()

    case let .displayUpdate(confirmedText, provisionalText):
      confirmedLiveText = QwenStreamingTextCleaner.clean(confirmedText)
      provisionalLiveText = QwenStreamingTextCleaner.clean(provisionalText)
      updateLiveSegments()

    case let .stats(stats):
      state.tokensPerSecond = stats.tokensPerSecond

    case let .ended(fullText):
      confirmedLiveText = QwenStreamingTextCleaner.clean(fullText)
      provisionalLiveText = ""
      updateLiveSegments()
      state.isWorking = false
    }
  }

  private func updateLiveSegments() {
    let confirmedText = confirmedLiveText.trimmingCharacters(in: .whitespacesAndNewlines)
    let provisionalText = provisionalLiveText.trimmingCharacters(in: .whitespacesAndNewlines)
    let endTimeMS = Self.milliseconds(forSample: liveAudioSampleCount)

    state.confirmedSegments = confirmedText.isEmpty
      ? []
      : [Segment(
        startTimeMS: 0,
        endTimeMS: endTimeMS,
        text: confirmedText,
        tokens: [],
        words: []
      )]
    state.unconfirmedSegments = provisionalText.isEmpty
      ? []
      : [Segment(
        startTimeMS: state.confirmedSegments.isEmpty ? 0 : max(1, endTimeMS - 1),
        endTimeMS: endTimeMS,
        text: provisionalText,
        tokens: [],
        words: []
      )]
    state.currentText = [confirmedText, provisionalText]
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private func updateDownloadProgress(_ progress: Double) {
    state.loadingProgressValue = Float(progress)
    state.modelState = .downloading
  }

  private static var generationParameters: STTGenerateParameters {
    STTGenerateParameters(
      maxTokens: 8192,
      language: nil,
      chunkDuration: 30,
      minChunkDuration: 1
    )
  }

  private static var streamingConfig: StreamingConfig {
    StreamingConfig(
      decodeIntervalSeconds: 2,
      boundaryDecodeIntervalSeconds: 0.5,
      delayPreset: .subtitle,
      language: nil,
      maxTokensPerPass: 1024,
      maxDecodeWindows: 2,
      finalizeCompletedWindows: true
    )
  }

  private static var qwenModelDirectory: URL {
    modelDirURL
      .appendingPathComponent("mlx-audio", isDirectory: true)
      .appendingPathComponent(Model.qwen3ASR.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
  }

  private static var isQwenModelLocal: Bool {
    let fileManager = FileManager.default
    let configURL = qwenModelDirectory.appendingPathComponent("config.json")
    guard fileManager.fileExists(atPath: configURL.path),
          let files = try? fileManager.contentsOfDirectory(at: qwenModelDirectory, includingPropertiesForKeys: nil)
    else {
      return false
    }
    return files.contains { $0.pathExtension == "safetensors" }
  }

  private static func milliseconds(forSample sample: Int) -> Int64 {
    Int64(Double(sample) / Double(sampleRate) * 1000)
  }

  private static func makeSegments(from output: STTOutput, fallbackDuration: Double) -> [Segment] {
    let segments = output.segments?.compactMap { rawSegment -> Segment? in
      guard let text = rawSegment["text"] as? String else { return nil }
      let start = rawSegment["start"] as? Double ?? 0
      let end = rawSegment["end"] as? Double ?? fallbackDuration
      return Segment(
        startTimeMS: Int64(start * 1000),
        endTimeMS: Int64(end * 1000),
        text: text.trimmingCharacters(in: .whitespacesAndNewlines),
        tokens: [],
        words: []
      )
    } ?? []

    if !segments.isEmpty {
      return segments
    }

    let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return [] }
    return [Segment(
      startTimeMS: 0,
      endTimeMS: Int64(fallbackDuration * 1000),
      text: text,
      tokens: [],
      words: []
    )]
  }
}

public extension TranscriptionStream.State {
  var segments: [Segment] {
    confirmedSegments + unconfirmedSegments
  }
}
