// MARK: - ProgressiveResult

public enum ProgressiveResult<Value, Progress> {
  case idle
  case inProgress(Progress)
  case success(Value)
  case error(EquatableError)
}

public extension ProgressiveResult where Progress == Void {
  static var inProgress: Self {
    .inProgress(())
  }
}

public extension ProgressiveResult {
  static func failure(_ error: Error) -> Self {
    .error(error.equatable)
  }

  var isIdle: Bool {
    guard case .idle = self else {
      return false
    }
    return true
  }

  var isInProgress: Bool {
    guard case .inProgress = self else {
      return false
    }
    return true
  }

  var isError: Bool {
    guard case .error = self else {
      return false
    }
    return true
  }
}

extension ProgressiveResult: Equatable where Value: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    switch (lhs, rhs) {
    case (.idle, .idle), (.inProgress, .inProgress):
      true

    case let (.success(lhsValue), .success(rhsValue)):
      lhsValue == rhsValue

    case let (.error(lhsError), .error(rhsError)):
      lhsError == rhsError

    default:
      false
    }
  }
}

public typealias ProgressiveResultOf<Value> = ProgressiveResult<Value, Void>
