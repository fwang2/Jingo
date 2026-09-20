import AudioProcessing
import ComposableArchitecture
import Foundation

extension SharedReaderKey where Self == FileStorageKey<[SpeakerProfile]>.Default {
  static var speakerProfiles: Self {
    Self[
      .fileStorage(.applicationSupportDirectory.appending(component: "speaker-profiles.json")),
      default: []
    ]
  }
}
