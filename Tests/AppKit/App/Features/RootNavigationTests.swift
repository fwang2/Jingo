import ComposableArchitecture
@testable import JingoKit
import XCTest

final class RootNavigationTests: XCTestCase {
  @MainActor
  func testBottomNavigationReplacesTheCurrentDestination() async {
    var initialState = Root.State()
    initialState.path.append(.settings)

    let store = TestStore(initialState: initialState) {
      Root()
    }

    await store.send(.homeButtonTapped) {
      $0.path.removeAll()
    }

    await store.send(.recordingListButtonTapped) {
      $0.path.append(.list)
    }

    await store.send(.settingsButtonTapped) {
      $0.path.removeAll()
      $0.path.append(.settings)
    }
  }
}
