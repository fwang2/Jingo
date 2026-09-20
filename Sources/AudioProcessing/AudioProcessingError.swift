import Foundation

enum AudioProcessingError: LocalizedError {
  case audioProcessingFailed(String)
  case loadAudioFailed(String)

  var errorDescription: String? {
    switch self {
    case let .audioProcessingFailed(message), let .loadAudioFailed(message):
      message
    }
  }
}
