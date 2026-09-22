import AppKit
import SwiftUI

@main
struct JingoMacApp: App {
  private let usesUITestWindow =
    ProcessInfo.processInfo.environment["JINGO_UI_TEST_WINDOWED"] == "1"

  var body: some Scene {
    WindowGroup {
      MacContentView()
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
          guard usesUITestWindow else { return }

          // UI tests should not inherit a developer's saved fullscreen window state.
          DispatchQueue.main.async {
            guard let window = NSApplication.shared.windows.first(where: \.isVisible) else { return }
            window.setContentSize(NSSize(width: 960, height: 700))
            window.center()
          }
        }
    }
    .windowStyle(.hiddenTitleBar)
  }
}
