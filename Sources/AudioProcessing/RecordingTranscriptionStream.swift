import Common
import ComposableArchitecture
import Dependencies
import Foundation

// MARK: - RecordingTranscriptionStream

@DependencyClient
public struct RecordingTranscriptionStream: Sendable {
  public var startRecording: @Sendable (_ fileURL: URL) async -> AsyncThrowingStream<RecordingStream.State, Error> = { _ in .finished() }
  public var startLiveTranscription: @Sendable () async -> AsyncThrowingStream<TranscriptionStream.State, Error> = { .finished() }
  public var transcribeAudioFile: @Sendable (URL, @escaping (TranscriptionStream.Progress, Double) -> Bool?) async throws -> TranscriptionStream
    .Result = { _, _ in
      throw NSError(domain: "RecordingTranscriptionStream", code: 0, userInfo: nil)
    }

  public var stopRecording: @Sendable () async -> Void = {}
  public var pauseRecording: @Sendable () async -> Void = {}
  public var resumeRecording: @Sendable () async -> Void = {}

  public var fetchModels: @Sendable () async throws -> [Model] = { [] }
  public var loadModel: @Sendable (String, @escaping @Sendable (Double) -> Void) async throws -> Void = { _, _ in }
  public var deleteModel: @Sendable (String) async throws -> Void = { _ in }
  public var recommendedModels: @Sendable () -> (default: String, disabled: [String]) = { (default: "", disabled: []) }
  public var deleteAllModels: @Sendable () async throws -> Void = {}
}

// MARK: DependencyKey

extension RecordingTranscriptionStream: DependencyKey {
  public static let testValue = RecordingTranscriptionStream(
    startRecording: { _ in .finished() },
    startLiveTranscription: { .finished() },
    transcribeAudioFile: { _, _ in throw CancellationError() },
    stopRecording: {},
    pauseRecording: {},
    resumeRecording: {},
    fetchModels: { [] },
    loadModel: { _, _ in },
    deleteModel: { _ in },
    recommendedModels: { (default: Model.defaultModelName, disabled: []) },
    deleteAllModels: {}
  )

  public static var liveValue: RecordingTranscriptionStream = liveValue(executionPolicy: .automatic)

  static func liveValue(
    executionPolicy: TranscriptionExecutionPolicy
  ) -> RecordingTranscriptionStream {
    let container = RecordingTranscriptionStreamContainer(
      forcedAlignmentClient: .liveValue,
      speakerDiarizationClient: .liveValue,
      executionPolicy: executionPolicy
    )

    return RecordingTranscriptionStream(
      startRecording: { fileURL in
        await container.startRecording(fileURL)
      },
      startLiveTranscription: {
        await container.startTranscriptionLoop()
      },
      transcribeAudioFile: { fileURL, callback in
        try await container.transcribeAudioFile(fileURL, callback: callback)
      },
      stopRecording: {
        await container.stopRecording()
      },
      pauseRecording: {
        await container.pauseRecording()
      },
      resumeRecording: {
        await container.resumeRecording()
      },
      fetchModels: {
        try await container.fetchModels()
      },
      loadModel: { model, progressCallback in
        try await container.loadModel(model, progressCallback: progressCallback)
      },
      deleteModel: { model in
        try await container.deleteModel(model)
      },
      recommendedModels: {
        (default: Model.defaultModelName, disabled: [])
      },
      deleteAllModels: {
        try await container.deleteAllModels()
      }
    )
  }
}

// MARK: - RecordingTranscriptionStreamContainer

private actor RecordingTranscriptionStreamContainer {
  let audioProcessor: AudioProcessor = .init()
  lazy var recordingStream = RecordingStream(audioProcessor: audioProcessor)
  lazy var transcriptionStream = TranscriptionStream(audioProcessor: audioProcessor)
  let forcedAlignmentClient: ForcedAlignmentClient
  let speakerDiarizationClient: SpeakerDiarizationClient
  let executionPolicy: TranscriptionExecutionPolicy

  init(
    forcedAlignmentClient: ForcedAlignmentClient,
    speakerDiarizationClient: SpeakerDiarizationClient,
    executionPolicy: TranscriptionExecutionPolicy
  ) {
    self.forcedAlignmentClient = forcedAlignmentClient
    self.speakerDiarizationClient = speakerDiarizationClient
    self.executionPolicy = executionPolicy
  }

  func startRecording(_ fileURL: URL) -> AsyncThrowingStream<RecordingStream.State, Error> {
    AsyncThrowingStream { [weak self] continuation in
      Task { [weak self] in
        guard let self else {
          return
        }

        do {
          await recordingStream.resetState()
          continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
              await self?.recordingStream.stopRecording()
            }
          }
          try await recordingStream.startRecording(at: fileURL) { state in
            continuation.yield(state)
          }
          continuation.finish()
        } catch {
          logs.error("Failed to perform recording \(error)")
          continuation.finish(throwing: error)
        }
      }
    }
  }

  func startTranscriptionLoop() -> AsyncThrowingStream<TranscriptionStream.State, Error> {
    AsyncThrowingStream { [weak self] continuation in
      Task { [weak self] in
        guard let self else {
          return
        }

        do {
          await transcriptionStream.resetState()
          continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
              await self?.transcriptionStream.stopRealtimeLoop()
            }
          }
          try await transcriptionStream.startRealtimeLoop { state in
            continuation.yield(state)
          }
          continuation.finish()
        } catch {
          logs.error("Failed to perform transcription \(error)")
          continuation.finish(throwing: error)
        }
      }
    }
  }

  func transcribeAudioFile(
    _ fileURL: URL,
    callback: @escaping (TranscriptionStream.Progress, Double) -> Bool?
  ) async throws -> TranscriptionStream.Result {
    switch executionPolicy {
    case .resourceConstrained:
      try await transcribeResourceConstrainedAudioFile(fileURL, callback: callback)
    case .highPerformance:
      try await transcribeHighPerformanceAudioFile(fileURL, callback: callback)
    }
  }

  private func transcribeResourceConstrainedAudioFile(
    _ fileURL: URL,
    callback: @escaping (TranscriptionStream.Progress, Double) -> Bool?
  ) async throws -> TranscriptionStream.Result {
    let startTime = Date()
    let transcription = try await transcriptionStream.transcribeAudioFile(fileURL) { progress, fraction in
      callback(progress, fraction * 0.6)
    }

    guard !transcription.text.isEmpty else {
      return transcription
    }

    let progress = TranscriptionStream.Progress(text: transcription.text)
    if callback(progress, 0.6) == false {
      throw CancellationError()
    }

    // These models are individually large enough that retaining them together can
    // trigger iOS memory-pressure termination. Run each stage with exclusive ownership.
    await transcriptionStream.unloadModel()

    do {
      let alignment = try await forcedAlignmentClient.align(fileURL, transcription.segments)
      await forcedAlignmentClient.unloadModel()
      if callback(progress, 0.8) == false {
        throw CancellationError()
      }

      let diarization = try await speakerDiarizationClient.diarize(fileURL) { _ in }
      await speakerDiarizationClient.unloadModels()
      let mergedSegments = SpeakerAttributedTranscriptionMerger.merge(
        transcript: transcription.text,
        alignedWords: alignment.words,
        speakerSegments: diarization.segments
      )
      try await transcriptionStream.loadModel(Model.defaultModelName)
      if callback(progress, 1) == false {
        throw CancellationError()
      }

      return makeResult(
        transcription: transcription,
        mergedSegments: mergedSegments,
        speakerEmbeddings: diarization.speakerEmbeddings,
        startTime: startTime
      )
    } catch {
      await forcedAlignmentClient.unloadModel()
      await speakerDiarizationClient.unloadModels()
      try? await transcriptionStream.loadModel(Model.defaultModelName)
      throw error
    }
  }

  private func transcribeHighPerformanceAudioFile(
    _ fileURL: URL,
    callback: @escaping (TranscriptionStream.Progress, Double) -> Bool?
  ) async throws -> TranscriptionStream.Result {
    let startTime = Date()
    let diarizationTask = Task {
      try await speakerDiarizationClient.diarize(fileURL) { _ in }
    }

    do {
      let transcription = try await transcriptionStream.transcribeAudioFile(fileURL) { progress, fraction in
        callback(progress, fraction * 0.65)
      }
      guard !transcription.text.isEmpty else {
        diarizationTask.cancel()
        return transcription
      }

      let progress = TranscriptionStream.Progress(text: transcription.text)
      if callback(progress, 0.65) == false {
        throw CancellationError()
      }

      let alignment = try await forcedAlignmentClient.align(fileURL, transcription.segments)
      if callback(progress, 0.9) == false {
        throw CancellationError()
      }

      let diarization = try await diarizationTask.value
      let mergedSegments = SpeakerAttributedTranscriptionMerger.merge(
        transcript: transcription.text,
        alignedWords: alignment.words,
        speakerSegments: diarization.segments
      )
      if callback(progress, 1) == false {
        throw CancellationError()
      }

      return makeResult(
        transcription: transcription,
        mergedSegments: mergedSegments,
        speakerEmbeddings: diarization.speakerEmbeddings,
        startTime: startTime
      )
    } catch {
      diarizationTask.cancel()
      throw error
    }
  }

  private func makeResult(
    transcription: TranscriptionStream.Result,
    mergedSegments: [Segment],
    speakerEmbeddings: [String: [Float]],
    startTime: Date
  ) -> TranscriptionStream.Result {
    let finalSegments = mergedSegments.isEmpty ? transcription.segments : mergedSegments
    let finalText = mergedSegments.isEmpty
      ? transcription.text
      : SpeakerAttributedTranscriptionMerger.restoredTranscript(
        from: mergedSegments,
        fallback: transcription.text
      )
    return TranscriptionStream.Result(
      text: finalText,
      segments: finalSegments,
      timings: .init(
        tokensPerSecond: transcription.timings.tokensPerSecond,
        fullPipeline: Date().timeIntervalSince(startTime)
      ),
      speakerEmbeddings: speakerEmbeddings
    )
  }

  func stopRecording() async {
    await recordingStream.stopRecording()
    await transcriptionStream.stopRealtimeLoop()
  }

  func pauseRecording() async {
    await recordingStream.pauseRecording()
  }

  func resumeRecording() async {
    await recordingStream.resumeRecording()
  }

  func fetchModels() async throws -> [Model] {
    try await transcriptionStream.fetchModels()
    return await getModelInfos()
  }

  func loadModel(_ model: String, progressCallback: @escaping @Sendable (Double) -> Void) async throws {
    logs.debug("Starting to load model: \(model)")
    switch executionPolicy {
    case .resourceConstrained:
      try await forcedAlignmentClient.prepareModels { progress in
        progressCallback(progress * 0.4)
      }
      await forcedAlignmentClient.unloadModel()
      try await speakerDiarizationClient.prepareModels()
      await speakerDiarizationClient.unloadModels()
      progressCallback(0.5)
      try await transcriptionStream.loadModel(model) { progress in
        progressCallback(0.5 + progress * 0.5)
      }

    case .highPerformance:
      async let prepareAlignment: Void = forcedAlignmentClient.prepareModels { _ in }
      async let prepareDiarization: Void = speakerDiarizationClient.prepareModels()
      try await transcriptionStream.loadModel(model) { progress in
        progressCallback(progress * 0.8)
      }
      try await prepareAlignment
      try await prepareDiarization
      progressCallback(1)
    }
    logs.debug("Model \(model) loaded successfully")
  }

  func deleteModel(_ model: String) async throws {
    await forcedAlignmentClient.unloadModel()
    await speakerDiarizationClient.unloadModels()
    try await transcriptionStream.deleteModel(model)
  }

  func deleteAllModels() async throws {
    await forcedAlignmentClient.unloadModel()
    await speakerDiarizationClient.unloadModels()
    try? FileManager.default.removeItem(at: TranscriptionStream.modelDirURL)
  }

  private func getModelInfos() async -> [Model] {
    let state = await transcriptionStream.state
    let defaultModel = Model.defaultModelName
    let disabledModels: [String] = []
    return state.availableModels.map { name in
      Model(
        name: name,
        isLocal: state.localModels.contains(name),
        isDefault: name == defaultModel,
        isDisabled: disabledModels.contains(name)
      )
    }
  }
}
