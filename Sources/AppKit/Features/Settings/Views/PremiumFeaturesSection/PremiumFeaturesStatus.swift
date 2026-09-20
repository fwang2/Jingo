import ComposableArchitecture

// MARK: - PremiumFeaturesStatus

public struct PremiumFeaturesStatus: Codable, Hashable {
  public var liveTranscriptionIsPurchased: Bool? = nil
  public var isProductFound: Bool? = nil
}

// MARK: - PremiumFeaturesProductID

public enum PremiumFeaturesProductID {
  public static let liveTranscription = "com.feiyiwang.Jingo.LiveTranscription"
}

public extension SharedReaderKey where Self == FileStorageKey<PremiumFeaturesStatus>.Default {
  static var premiumFeatures: Self {
    Self[.fileStorage(.documentsDirectory.appending(component: "premiumFeatures.json")), default: PremiumFeaturesStatus()]
  }
}
