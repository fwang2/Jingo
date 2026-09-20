import ComposableArchitecture
import Dependencies
import Foundation
import UIKit

extension DependencyValues {
  var didBecomeActive: @Sendable () async -> AsyncStream<Void> {
    get { self[DidBecomeActiveKey.self] }
    set { self[DidBecomeActiveKey.self] = newValue }
  }

  var willEnterForeground: @Sendable () async -> AsyncStream<Void> {
    get { self[WillEnterForegroundKey.self] }
    set { self[WillEnterForegroundKey.self] = newValue }
  }

  var didEnterBackground: @Sendable () async -> AsyncStream<Void> {
    get { self[DidEnterBackgroundKey.self] }
    set { self[DidEnterBackgroundKey.self] = newValue }
  }
}

// MARK: - DidBecomeActiveKey

private enum DidBecomeActiveKey: DependencyKey {
  static let liveValue: @Sendable () async -> AsyncStream<Void> = {
    notificationStream(named: UIApplication.didBecomeActiveNotification)
  }
}

// MARK: - WillEnterForegroundKey

private enum WillEnterForegroundKey: DependencyKey {
  static let liveValue: @Sendable () async -> AsyncStream<Void> = {
    notificationStream(named: UIApplication.willEnterForegroundNotification)
  }
}

// MARK: - DidEnterBackgroundKey

private enum DidEnterBackgroundKey: DependencyKey {
  static let liveValue: @Sendable () async -> AsyncStream<Void> = {
    notificationStream(named: UIApplication.didEnterBackgroundNotification)
  }
}

private func notificationStream(named name: Notification.Name) -> AsyncStream<Void> {
  AsyncStream { continuation in
    let observer = LockIsolated<NSObjectProtocol?>(nil)
    observer.setValue(
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
        continuation.yield()
      }
    )
    continuation.onTermination = { _ in
      if let token = observer.value {
        NotificationCenter.default.removeObserver(token)
      }
    }
  }
}
