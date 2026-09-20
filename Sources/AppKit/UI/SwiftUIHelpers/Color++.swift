import DynamicColor
import SwiftUI

extension Color {
  func lighten(by amount: CGFloat = 0.2) -> Color {
    Color(DynamicColor(self).lighter(amount: amount))
  }

  func darken(by amount: CGFloat = 0.2) -> Color {
    Color(DynamicColor(self).darkened(amount: amount))
  }

  static let systemBlue: Color = .init(DynamicColor.systemBlue)
  static let systemGreen: Color = .init(DynamicColor.systemGreen)
  static let systemOrange: Color = .init(DynamicColor.systemOrange)
  static let systemPurple: Color = .init(DynamicColor.systemPurple)
  static let systemRed: Color = .init(DynamicColor.systemRed)
  static let systemTeal: Color = .init(DynamicColor.systemTeal)
  static let systemYellow: Color = .init(DynamicColor.systemYellow)
}
