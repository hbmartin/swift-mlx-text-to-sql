import Foundation

/// The hardware floor for running the bundled 4-bit 3B SQL model on device.
///
/// The bundled `SQLModel` is roughly 1.75 GB resident once loaded. Below the
/// floor the app is jetsammed during model preparation rather than answering
/// slowly, so the floor is enforced before any model load is attempted rather
/// than surfaced as a runtime failure.
public enum DeviceCapability: Sendable {
  /// The lowest supported iPhone: iPhone 15 (`iPhone15,4`).
  ///
  /// The major/minor split matters. Apple's identifier families do not line up
  /// with marketing names across this exact boundary: `iPhone15,2` and
  /// `iPhone15,3` are the iPhone 14 Pro and 14 Pro Max, while `iPhone15,4` and
  /// `iPhone15,5` are the iPhone 15 and 15 Plus. A plain `major >= 15`
  /// comparison would admit both iPhone 14 Pro models.
  static let minimumMajor = 15
  static let minimumMinorAtMinimumMajor = 4

  /// Whether the identifier names an iPhone at or above the floor.
  ///
  /// Anything that is not an `iPhone<major>,<minor>` identifier is
  /// unsupported: iPad running the iPhone app in compatibility mode, and the
  /// bare `arm64` a simulator reports when it does not expose a model
  /// identifier.
  public static func isSupported(identifier: String) -> Bool {
    guard let (major, minor) = iPhoneVersion(identifier: identifier) else {
      return false
    }
    if major > minimumMajor { return true }
    if major < minimumMajor { return false }
    return minor >= minimumMinorAtMinimumMajor
  }

  /// Parses `iPhone<major>,<minor>`, rejecting every other shape.
  static func iPhoneVersion(identifier: String) -> (major: Int, minor: Int)? {
    guard identifier.hasPrefix("iPhone") else { return nil }
    let version = identifier.dropFirst("iPhone".count)
    let parts = version.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 2,
      let major = Int(parts[0]),
      let minor = Int(parts[1])
    else { return nil }
    return (major, minor)
  }

  /// The current device's hardware identifier.
  ///
  /// A simulator reports `arm64` from `hw.machine`, so the identifier it
  /// exports for the simulated device is preferred when present.
  public static var currentIdentifier: String {
    if let simulated = ProcessInfo.processInfo
      .environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty
    {
      return simulated
    }
    var size = 0
    guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
      return ""
    }
    var value = [UInt8](repeating: 0, count: size)
    guard sysctlbyname("hw.machine", &value, &size, nil, 0) == 0 else {
      return ""
    }
    if let terminator = value.firstIndex(of: 0) {
      value.removeSubrange(terminator...)
    }
    return String(decoding: value, as: UTF8.self)
  }

  /// Whether this device may load the bundled model.
  ///
  /// Debug builds always pass so the simulator, SwiftUI previews, and
  /// development on older hardware are unaffected. Beta and Release builds
  /// enforce the floor.
  public static var isCurrentDeviceSupported: Bool {
    #if DEBUG
      return true
    #else
      return isSupported(identifier: currentIdentifier)
    #endif
  }

  /// The user-facing requirement, shared by the wall and the pipeline guard.
  public static let requirementMessage =
    "CREG requires iPhone 15 or newer to run its on-device SQL model."
}
