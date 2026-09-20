import SwiftUI

extension View {
  func previewBasePreset() -> some View {
    ZStack {
      Color(.systemBackground).ignoresSafeArea()
      padding()
    }
    .environment(\.colorScheme, .dark)
  }
}
