@testable import AudioProcessing
import Common
import XCTest

class AudioProcessingTests: XCTestCase {
  private var recordingTranscriptionStream: RecordingTranscriptionStream?

  override func setUp() {
    super.setUp()
    recordingTranscriptionStream = RecordingTranscriptionStream.liveValue
  }

  override func tearDown() {
    recordingTranscriptionStream = nil
    super.tearDown()
  }

  func testAudioFileTranscription() async throws {
    #if targetEnvironment(simulator)
      throw XCTSkip("Qwen3-ASR integration inference must run on a physical Apple Silicon iOS device.")
    #else
      // 1. Prepare the test audio file
      let bundle = Bundle(for: type(of: self))
      guard let audioURL = bundle.url(forResource: "example", withExtension: "wav") else {
        XCTFail("Test audio file not found")
        return
      }

      // 2. Load the model
      let modelName = Model.defaultModelName
      let recordingTranscriptionStream = try XCTUnwrap(recordingTranscriptionStream)
      try await recordingTranscriptionStream.loadModel(modelName) { _ in }

      // 3. Transcribe the audio file
      let result = try await recordingTranscriptionStream.transcribeAudioFile(audioURL) { _, _ in true }

      // 4. Validate the transcription result
      XCTAssertFalse(result.text.isEmpty, "Transcription text should not be empty")
      XCTAssertFalse(result.segments.isEmpty, "Transcription segments should not be empty")
      XCTAssertTrue(result.segments.contains { $0.speaker != nil }, "At least one segment should have a speaker")
      XCTAssertTrue(result.segments.contains { !$0.words.isEmpty }, "At least one segment should contain aligned words")

      // 5. Compare with expected transcription
      let expectedText = "In the heart of a bustling city"
      XCTAssertTrue(
        result.text.lowercased().contains(expectedText.lowercased()),
        "Expected \(expectedText), got: \(result.text)"
      )

      // 6. Check transcription timings
      XCTAssertGreaterThan(result.timings.tokensPerSecond, 0, "Tokens per second should be greater than 0")
      XCTAssertGreaterThan(result.timings.fullPipeline, 0, "Full pipeline time should be greater than 0")
    #endif
  }

  func testAudioFileConversionProducesQwenInputFormat() throws {
    let bundle = Bundle(for: type(of: self))
    let audioURL = try XCTUnwrap(bundle.url(forResource: "example", withExtension: "wav"))

    let buffer = try AudioProcessor.loadAudio(fromPath: audioURL.path)
    let samples = AudioProcessor.convertBufferToArray(buffer: buffer)

    XCTAssertEqual(buffer.format.sampleRate, 16000)
    XCTAssertEqual(buffer.format.channelCount, 1)
    XCTAssertFalse(samples.isEmpty)
  }

  func testCleanQwenStreamingTextRemovesDetectedLanguagePrefix() {
    XCTAssertEqual(
      QwenStreamingTextCleaner.clean(
        "language English<asr_text>Hello, this is a test."
      ),
      "Hello, this is a test."
    )
  }

  func testCleanQwenStreamingTextPreservesBilingualTranscript() {
    XCTAssertEqual(
      QwenStreamingTextCleaner.clean(
        "language English<asr_text>Hello. language Chinese<asr_text>你好，这是测试。"
      ),
      "Hello. 你好，这是测试。"
    )
  }

  func testCleanQwenStreamingTextHidesIncompletePrefix() {
    XCTAssertEqual(QwenStreamingTextCleaner.clean("language"), "")
    XCTAssertEqual(QwenStreamingTextCleaner.clean("language Chinese"), "")
  }

  func testCleanQwenStreamingTextPreservesSpokenWordLanguage() {
    XCTAssertEqual(
      QwenStreamingTextCleaner.clean("I study language"),
      "I study language"
    )
  }

  func testCleanQwenStreamingTextHandlesPrefixSplitAcrossUpdates() {
    XCTAssertEqual(
      QwenStreamingTextCleaner.clean("Hello. language"),
      "Hello."
    )
    XCTAssertEqual(
      QwenStreamingTextCleaner.clean(" Chinese<asr_text>你好。"),
      "你好。"
    )
  }
}
