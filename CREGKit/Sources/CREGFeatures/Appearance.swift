import SwiftUI

/// The theme CREG renders in.
///
/// The app ships no `UIUserInterfaceStyle`, so `.system` — the default — is a
/// real deferral to iOS, including its automatic Light/Dark schedule. The
/// other two cases are an explicit override the user sets in Settings; it is
/// persisted in user defaults and applied at the root, so it covers sheets and
/// the browser drawer as well as the chat.
public enum AppearancePreference: String, CaseIterable, Sendable, Equatable {
  case system
  case light
  case dark

  /// The key backing the persisted override; the picker and the root view are
  /// the only readers.
  public static let storageKey = "appearancePreference"

  public var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  /// `nil` hands the decision back to SwiftUI, which is what makes `.system`
  /// follow the device rather than freeze whatever was showing at launch.
  public var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}
