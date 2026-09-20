import Foundation

public extension Optional {
  struct RequireError: Error, CustomStringConvertible {
    let function: StaticString
    let file: StaticString
    let line: UInt
    let message: String

    public var description: String {
      "\(URL(fileURLWithPath: "\(file)").lastPathComponent):\(line) \(function) Required optional value was nil. \(message)"
    }
  }

  func require(
    orThrow errorClosure: (() -> Error)? = nil,
    function: StaticString = #function,
    file: StaticString = #file,
    line: UInt = #line
  ) throws -> Wrapped {
    guard let value = self else {
      throw errorClosure?() ?? RequireError(function: function, file: file, line: line, message: "")
    }

    return value
  }
}
