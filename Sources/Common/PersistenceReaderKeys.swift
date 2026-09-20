import ComposableArchitecture
import Foundation

public extension SharedReaderKey where Self == FileStorageKey<IdentifiedArrayOf<RecordingInfo>>.Default {
  static var recordings: Self {
    Self[.fileStorage(.documentsDirectory.appending(component: "recordings.json")), default: []]
  }
}

public extension SharedReaderKey where Self == InMemoryKey<IdentifiedArrayOf<TranscriptionTask>>.Default {
  static var transcriptionTasks: Self {
    Self[.inMemory(#function), default: []]
  }
}

public extension SharedReaderKey where Self == InMemoryKey<Bool>.Default {
  static var isICloudSyncInProgress: Self {
    Self[.inMemory(#function), default: false]
  }
}

public extension SharedReaderKey where Self == FileStorageKey<Settings> {
  static var settings: Self {
    .fileStorage(.documentsDirectory.appending(component: "settings.json"))
  }
}
