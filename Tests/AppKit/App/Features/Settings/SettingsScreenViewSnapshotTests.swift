import ComposableArchitecture
import Dependencies
@testable import JingoKit
import SnapshotTesting
import SwiftUI
import XCTest

class SettingsScreenViewSnapshotTests: XCTestCase {
  func testSettingsScreenView() {
    let state = SettingsScreen.State()
    state.$speakerProfiles.withLock { $0 = [] }
    state.$recordings.withLock { $0 = [] }
    let store: StoreOf<SettingsScreen> = Store(initialState: state) {
      SettingsScreen()
    } withDependencies: {
      $0.build.version = { "1.0.0" }
      $0.build.buildNumber = { "100" }
      $0[StorageClient.self].freeSpace = { @Sendable in 1_000_000_000 }
      $0[StorageClient.self].takenSpace = { @Sendable in 500_000_000 }
    }

    let view = SettingsScreenView(store: store)
      .background(Color.DS.Background.primary)
      .environment(\.colorScheme, .dark)

    assertSnapshots(
      of: view,
      as: [
        .image(layout: .device(config: .iPhone13ProMax), traits: .iPhone13ProMax(.portrait)),
        .image(layout: .device(config: .iPhoneSe), traits: .iPhoneSe(.portrait)),
        .image(layout: .device(config: .iPadPro12_9), traits: .iPadPro12_9),
        .image(layout: .device(config: .iPadMini), traits: .iPadMini),
      ]
    )
  }
}
