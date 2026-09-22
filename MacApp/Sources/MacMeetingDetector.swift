import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - MacMeetingProvider

enum MacMeetingProvider: String, Sendable {
  case teams
  case zoom

  var displayName: String {
    switch self {
    case .teams:
      "Microsoft Teams"

    case .zoom:
      "Zoom"
    }
  }

  static func identify(bundleIdentifier: String?, applicationName: String?) -> Self? {
    let bundleIdentifier = bundleIdentifier?.lowercased() ?? ""
    let applicationName = applicationName?.lowercased() ?? ""

    if bundleIdentifier == "us.zoom.xos" || applicationName == "zoom.us"
      || applicationName == "zoom workplace" {
      return .zoom
    }
    if bundleIdentifier == "com.microsoft.teams" || bundleIdentifier == "com.microsoft.teams2"
      || applicationName.hasPrefix("microsoft teams") {
      return .teams
    }
    return nil
  }

  func isLikelyMeetingWindow(title: String?, frame: CGRect) -> Bool {
    guard frame.width >= 300, frame.height >= 180 else {
      return false
    }
    let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    guard !title.isEmpty else {
      return false
    }

    switch self {
    case .zoom:
      return [
        "zoom meeting",
        "zoom webinar",
        "waiting for host",
        "breakout room",
      ].contains(where: title.contains)

    case .teams:
      return [
        "meeting | microsoft teams",
        "microsoft teams meeting",
        "microsoft teams call",
        "call with ",
      ].contains(where: title.contains)
    }
  }
}

// MARK: - MacMeetingDetection

struct MacMeetingDetection: Equatable, Sendable {
  let provider: MacMeetingProvider
}

// MARK: - MacMeetingDetector

@MainActor
enum MacMeetingDetector {
  static func detectActiveMeeting() async -> MacMeetingDetection? {
    // Enumerating other apps' windows with ScreenCaptureKit prompts for Screen
    // Recording access. Automatic mode must remain microphone-only until the
    // user has explicitly granted that permission for online-meeting capture.
    guard CGPreflightScreenCaptureAccess() else {
      return nil
    }

    var runningProvidersByBundleIdentifier: [String: MacMeetingProvider] = [:]
    for application in NSWorkspace.shared.runningApplications {
      guard let provider = MacMeetingProvider.identify(
        bundleIdentifier: application.bundleIdentifier,
        applicationName: application.localizedName
      ), let bundleIdentifier = application.bundleIdentifier
      else {
        continue
      }
      runningProvidersByBundleIdentifier[bundleIdentifier] = provider
    }
    guard !runningProvidersByBundleIdentifier.isEmpty else {
      return nil
    }

    guard let content = try? await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: false
    ) else {
      return nil
    }

    for window in content.windows {
      guard let bundleIdentifier = window.owningApplication?.bundleIdentifier,
            let provider = runningProvidersByBundleIdentifier[bundleIdentifier],
            provider.isLikelyMeetingWindow(title: window.title, frame: window.frame)
      else {
        continue
      }
      return MacMeetingDetection(provider: provider)
    }
    return nil
  }
}
