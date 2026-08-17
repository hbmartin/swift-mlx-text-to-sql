import ComposableArchitecture
import Foundation

#if canImport(UIKit)
  import UIKit
#endif

// MARK: - App icon

/// The three shipped app icons. Raw values are the `.icon` document names wired
/// into `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`; the primary is
/// addressed as `nil` because that is what UIKit expects.
public enum AppIconVariant: String, CaseIterable, Sendable, Equatable {
  case midnight = "AppIconMidnight"
  case indigo = "AppIconIndigo"
  case midnightGold = "AppIconMidnightGold"

  public var isPrimary: Bool { self == .midnight }

  /// `nil` restores the primary icon.
  public var alternateName: String? { isPrimary ? nil : rawValue }

  public var title: String {
    switch self {
    case .midnight: "Midnight"
    case .indigo: "Indigo"
    case .midnightGold: "Midnight Gold"
    }
  }

  public init(alternateName: String?) {
    self = AppIconVariant(rawValue: alternateName ?? "") ?? .midnight
  }
}

/// Reads and switches the home-screen icon.
///
/// Switching always surfaces a system alert that cannot be suppressed, so this
/// is only ever driven by an explicit tap in Settings.
public struct AppIconClient: Sendable {
  public var current: @Sendable () async -> AppIconVariant
  public var select: @Sendable (AppIconVariant) async throws -> Void
  /// False when the platform or the built Info.plist has no alternates, which
  /// makes it a useful canary for the asset-catalog wiring.
  public var supportsAlternates: @Sendable () async -> Bool

  public init(
    current: @escaping @Sendable () async -> AppIconVariant,
    select: @escaping @Sendable (AppIconVariant) async throws -> Void,
    supportsAlternates: @escaping @Sendable () async -> Bool
  ) {
    self.current = current
    self.select = select
    self.supportsAlternates = supportsAlternates
  }
}

extension AppIconClient {
  public static let noop = AppIconClient(
    current: { .midnight },
    select: { _ in },
    supportsAlternates: { false })

  public static func live() -> AppIconClient {
    AppIconClient(
      current: {
        #if canImport(UIKit)
          await MainActor.run {
            AppIconVariant(alternateName: UIApplication.shared.alternateIconName)
          }
        #else
          .midnight
        #endif
      },
      select: { variant in
        #if canImport(UIKit)
          try await applyAlternateIcon(variant.alternateName)
        #endif
      },
      supportsAlternates: {
        #if canImport(UIKit)
          await MainActor.run { UIApplication.shared.supportsAlternateIcons }
        #else
          false
        #endif
      })
  }
}

extension AppIconClient: DependencyKey {
  public static var testValue: AppIconClient { .noop }
  public static var liveValue: AppIconClient { .live() }
}

#if canImport(UIKit)
  /// `UIApplication` is main-actor isolated and not `Sendable`, so the hop has
  /// to happen around the call rather than around the instance.
  @MainActor
  private func applyAlternateIcon(_ name: String?) async throws {
    try await UIApplication.shared.setAlternateIconName(name)
  }
#endif
