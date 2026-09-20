import SwiftUI

public extension View {
  func scrollAnchor(id _: some Hashable, valueToTrack _: some Equatable, anchor: UnitPoint = .bottom) -> some View {
    defaultScrollAnchor(anchor)
  }
}
