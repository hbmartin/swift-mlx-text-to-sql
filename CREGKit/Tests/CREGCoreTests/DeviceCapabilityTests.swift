import Foundation
import Testing

@testable import CREGCore

@Suite struct DeviceCapabilityTests {
  /// The identifier families straddle the marketing boundary: `iPhone15,2` and
  /// `iPhone15,3` are the iPhone 14 Pro and 14 Pro Max, not iPhone 15 models.
  @Test func rejectsEveryIPhoneBelowTheFloor() {
    #expect(!DeviceCapability.isSupported(identifier: "iPhone12,1"))
    #expect(!DeviceCapability.isSupported(identifier: "iPhone14,5"))
    #expect(!DeviceCapability.isSupported(identifier: "iPhone14,7"))
    #expect(!DeviceCapability.isSupported(identifier: "iPhone14,8"))
    #expect(!DeviceCapability.isSupported(identifier: "iPhone15,2"))
    #expect(!DeviceCapability.isSupported(identifier: "iPhone15,3"))
  }

  @Test func acceptsIPhone15AndNewer() {
    #expect(DeviceCapability.isSupported(identifier: "iPhone15,4"))
    #expect(DeviceCapability.isSupported(identifier: "iPhone15,5"))
    #expect(DeviceCapability.isSupported(identifier: "iPhone16,1"))
    #expect(DeviceCapability.isSupported(identifier: "iPhone16,2"))
    #expect(DeviceCapability.isSupported(identifier: "iPhone17,1"))
    #expect(DeviceCapability.isSupported(identifier: "iPhone17,3"))
    #expect(DeviceCapability.isSupported(identifier: "iPhone17,5"))
    #expect(DeviceCapability.isSupported(identifier: "iPhone18,1"))
    #expect(DeviceCapability.isSupported(identifier: "iPhone18,4"))
  }

  @Test func rejectsNonIPhoneAndMalformedIdentifiers() {
    #expect(!DeviceCapability.isSupported(identifier: "arm64"))
    #expect(!DeviceCapability.isSupported(identifier: "x86_64"))
    #expect(!DeviceCapability.isSupported(identifier: ""))
    #expect(!DeviceCapability.isSupported(identifier: "iPad14,3"))
    #expect(!DeviceCapability.isSupported(identifier: "iPad16,6"))
    // A prefix match alone must not qualify.
    #expect(!DeviceCapability.isSupported(identifier: "iPhone"))
    #expect(!DeviceCapability.isSupported(identifier: "iPhone16"))
    #expect(!DeviceCapability.isSupported(identifier: "iPhone16,"))
    #expect(!DeviceCapability.isSupported(identifier: "iPhone16,1,2"))
    #expect(!DeviceCapability.isSupported(identifier: "iPhoneSimulator16,1"))
  }

  @Test func parsesVersionComponents() {
    let parsed = DeviceCapability.iPhoneVersion(identifier: "iPhone17,3")
    #expect(parsed?.major == 17)
    #expect(parsed?.minor == 3)
    #expect(DeviceCapability.iPhoneVersion(identifier: "iPad14,3") == nil)
  }
}
