import Foundation

public extension String {
  var lastPathComponent: String {
    components(separatedBy: "/").last ?? self
  }

  func appendingPathComponent(_ component: String) -> String {
    hasSuffix("/") ? appending(component) : appending("/" + component)
  }

  var titleCased: String {
    replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression, range: range(of: self))
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .capitalized
  }
}

public extension StaticString {
  var lastPathComponent: String {
    "\(self)".lastPathComponent
  }
}
