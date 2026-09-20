import SwiftUI

@main
struct JingoMacApp: App {
  var body: some Scene {
    WindowGroup {
      MacContentView()
        .frame(minWidth: 720, minHeight: 520)
    }
    .windowStyle(.hiddenTitleBar)
  }
}
