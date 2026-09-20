import ComposableArchitecture

public extension AlertState {
  static func error(_ error: Error) -> Self {
    Self {
      TextState("Something went wrong")
    } actions: {
    } message: {
      TextState(error.localizedDescription)
    }
  }

  static func error(message: String) -> Self {
    Self {
      TextState("Something went wrong")
    } actions: {
    } message: {
      TextState(message)
    }
  }

  static var genericError: Self {
    Self {
      TextState("Something went wrong")
    } actions: {
    } message: {
      TextState("Please try again later.")
    }
  }
}
