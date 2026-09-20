import Foundation

extension UInt64 {
  var readableString: String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useAll]
    formatter.countStyle = .memory
    return formatter.string(fromByteCount: Int64(self))
  }
}
