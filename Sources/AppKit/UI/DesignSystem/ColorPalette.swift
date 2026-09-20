import SwiftUI

// MARK: - Color.DS

extension Color {
  enum DS {
    static let neutral01100 = Color(red: 0.995, green: 0.995, blue: 0.995, opacity: 1)
    static let neutral04100 = Color(red: 0.423, green: 0.446, blue: 0.458, opacity: 1)
    static let neutral0550 = Color(red: 0.205, green: 0.220, blue: 0.225, opacity: 0.5)
    static let neutral06100 = Color(red: 0.137, green: 0.149, blue: 0.152, opacity: 1)
    static let neutral07100 = Color(red: 0.078, green: 0.090, blue: 0.094, opacity: 1)
    static let primary02 = Color(red: 0.555, green: 0.334, blue: 0.916, opacity: 1)
    static let primary01100 = Color(red: 0.854, green: 0.223, blue: 0.007, opacity: 1)
    static let accents05 = Color(red: 0.866, green: 0.655, blue: 0.245, opacity: 1)
    static let accents03 = Color(red: 0.247, green: 0.866, blue: 0.470, opacity: 1)
    static let code02 = Color(red: 0.699, green: 0.908, blue: 0.601, opacity: 1)
    static let code03 = Color(red: 0.982, green: 0.410, blue: 0.165, opacity: 1)
    static let code04 = Color(red: 1, green: 0.593, blue: 0.910, opacity: 1)

    enum Background {
      static var primary = Color.DS.neutral07100
      static var secondary = Color.DS.neutral06100
      static var tertiary = Color.DS.neutral0550
      static var accent = Color.DS.primary01100
      static var accentAlt = Color.DS.primary02
      static var error = Color.DS.primary01100
      static var success = Color.DS.accents03
      static var warning = Color.DS.accents05
    }

    enum Text {
      static var base = Color.DS.neutral01100
      static var subdued = Color.DS.neutral04100
      static var accent = Color.DS.primary01100
      static var accentAlt = Color.DS.primary02
      static var error = Color.DS.primary01100
      static var success = Color.DS.accents03
      static var warning = Color.DS.accents05
      static var overAccent = Color.DS.neutral01100
    }
  }
}
