import AppKit
import Foundation

// MARK: - MacSyncFolderStatus

enum MacSyncFolderStatus: Equatable, Sendable {
  case checking
  case available(URL)
  case notConfigured
  case unavailable(String)

  var title: String {
    switch self {
    case .checking:
      "Checking cloud sync…"

    case let .available(url):
      url.lastPathComponent

    case .notConfigured:
      "No cloud-synced folder selected"

    case .unavailable:
      "Cloud-synced folder unavailable"
    }
  }

  var detail: String {
    switch self {
    case .checking:
      "Jingo is checking the folder used for settings and recording backups."

    case let .available(url):
      url.path(percentEncoded: false)

    case .notConfigured:
      "Choose a location from iCloud Drive, Dropbox, Google Drive, OneDrive, or another sync service."

    case let .unavailable(message):
      message
    }
  }

  var isAvailable: Bool {
    if case .available = self {
      return true
    }
    return false
  }

  var guidance: String {
    switch self {
    case let .available(url)
      where url.lastPathComponent.caseInsensitiveCompare("Jingo") != .orderedSame:
      "This existing folder is used directly. Change the cloud location to have Jingo create a Jingo folder inside your selection."

    case .available:
      "Jingo created or reused this folder inside the cloud-synced location you selected."

    case .checking, .notConfigured, .unavailable:
      "Select a cloud-synced location. Jingo creates and uses a Jingo folder inside it—you do not need to create the folder yourself."
    }
  }
}

// MARK: - MacSyncFolderAccess

final class MacSyncFolderAccess: @unchecked Sendable {
  private static let bookmarkDefaultsKey = "mac.syncFolderBookmark"

  private let fileManager: FileManager
  private let defaults: UserDefaults
  private let lock = NSLock()
  private var folderURL: URL?
  private var isAccessingSecurityScopedResource = false

  init(
    fileManager: FileManager = .default,
    defaults: UserDefaults = .standard
  ) {
    self.fileManager = fileManager
    self.defaults = defaults
    restoreBookmark()
  }

  deinit {
    lock.withLock {
      if isAccessingSecurityScopedResource {
        folderURL?.stopAccessingSecurityScopedResource()
      }
    }
  }

  func selectedFolderURL() -> URL? {
    lock.withLock { folderURL }
  }

  func status() -> MacSyncFolderStatus {
    guard let url = selectedFolderURL() else {
      return .notConfigured
    }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else {
      return .unavailable(
        "The selected folder is not available. Reconnect its drive or choose another folder."
      )
    }
    return .available(url)
  }

  @MainActor
  func chooseFolder() throws -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Choose Cloud-Synced Location"
    panel.message = "Choose a location in iCloud Drive, Dropbox, Google Drive, OneDrive, "
      + "or another sync service. Jingo will create a Jingo folder inside it."
    panel.prompt = "Use This Location"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.directoryURL = preferredInitialFolder()

    guard panel.runModal() == .OK, let url = panel.url else {
      return nil
    }
    return try useLocation(url)
  }

  @discardableResult
  func useLocation(_ locationURL: URL) throws -> URL {
    let standardizedLocation = locationURL.standardizedFileURL
    let startedAccessingLocation = standardizedLocation.startAccessingSecurityScopedResource()
    defer {
      if startedAccessingLocation {
        standardizedLocation.stopAccessingSecurityScopedResource()
      }
    }
    let jingoFolderURL = standardizedLocation.lastPathComponent.caseInsensitiveCompare("Jingo") == .orderedSame
      ? standardizedLocation
      : standardizedLocation.appendingPathComponent("Jingo", isDirectory: true)
    try fileManager.createDirectory(at: jingoFolderURL, withIntermediateDirectories: true)
    try remember(jingoFolderURL)
    return jingoFolderURL
  }

  func remember(_ url: URL) throws {
    let bookmark = try url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    let startedAccessing = url.startAccessingSecurityScopedResource()
    lock.withLock {
      if isAccessingSecurityScopedResource {
        folderURL?.stopAccessingSecurityScopedResource()
      }
      folderURL = url
      isAccessingSecurityScopedResource = startedAccessing
    }
    defaults.set(bookmark, forKey: Self.bookmarkDefaultsKey)
  }

  private func preferredInitialFolder() -> URL {
    if let selectedURL = selectedFolderURL() {
      return selectedURL.lastPathComponent.caseInsensitiveCompare("Jingo") == .orderedSame
        ? selectedURL.deletingLastPathComponent()
        : selectedURL
    }

    let iCloudDriveURL = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: iCloudDriveURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue
    else {
      return fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? fileManager.homeDirectoryForCurrentUser
    }

    return iCloudDriveURL
  }

  private func restoreBookmark() {
    guard let bookmark = defaults.data(forKey: Self.bookmarkDefaultsKey) else {
      return
    }
    var isStale = false
    guard let url = try? URL(
      resolvingBookmarkData: bookmark,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    ) else {
      defaults.removeObject(forKey: Self.bookmarkDefaultsKey)
      return
    }
    let startedAccessing = url.startAccessingSecurityScopedResource()
    lock.withLock {
      folderURL = url
      isAccessingSecurityScopedResource = startedAccessing
    }
    if isStale {
      try? remember(url)
    }
  }
}
