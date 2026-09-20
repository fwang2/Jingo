import Foundation

// MARK: - TranscriptionExecutionPolicy

enum TranscriptionExecutionPolicy: Equatable, Sendable {
  case resourceConstrained
  case highPerformance

  static var automatic: Self {
    #if os(macOS)
      .highPerformance
    #else
      .resourceConstrained
    #endif
  }

  var keepsAuxiliaryModelsResident: Bool {
    self == .highPerformance
  }

  var runsDiarizationAlongsideTranscription: Bool {
    self == .highPerformance
  }
}
