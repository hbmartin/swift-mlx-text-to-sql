import CREGCore
import Darwin
import Foundation
import MLX

public enum ModelRuntimeDiagnostics {
  public static func memoryContext(prefix: String = "memory") -> [String: String] {
    let snapshot = Memory.snapshot()
    var context = [
      "\(prefix)_active_mb": megabytes(snapshot.activeMemory),
      "\(prefix)_cache_mb": megabytes(snapshot.cacheMemory),
      "\(prefix)_peak_mb": megabytes(snapshot.peakMemory),
    ]
    if let footprint = physicalFootprint() {
      context["\(prefix)_phys_footprint_mb"] = megabytes(clamping: footprint)
    }
    context["thermal_state"] = thermalStateName(ProcessInfo.processInfo.thermalState)
    return context
  }

  /// Discard allocator cache, never active weights or an in-flight array.
  public static func relievePressure() -> [String: String] {
    Memory.clearCache()
    return memoryContext(prefix: "pressure")
  }

  /// One worker owns cache eviction while warnings arrive in a burst.
  public static func relievePressureAsync() async -> [String: String]? {
    await PressureEviction.shared.run()
  }

  public static func deviceContext() -> [String: String] {
    let info = GPU.deviceInfo()
    return [
      "gpu_architecture": info.architecture,
      "gpu_recommended_working_set_mb": megabytes(
        clamping: info.maxRecommendedWorkingSetSize),
      "physical_memory_mb": megabytes(
        clamping: ProcessInfo.processInfo.physicalMemory),
    ]
  }

  private static func megabytes(_ bytes: Int) -> String {
    String(max(0, bytes) / (1024 * 1024))
  }

  private static func megabytes(clamping bytes: UInt64) -> String {
    String(bytes / UInt64(1024 * 1024))
  }

  private static func physicalFootprint() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return status == KERN_SUCCESS ? info.phys_footprint : nil
  }

  private static func thermalStateName(
    _ state: ProcessInfo.ThermalState
  ) -> String {
    switch state {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
  }
}

private actor PressureEviction {
  static let shared = PressureEviction()
  private var inFlight = false
  private var lastRelief = Date.distantPast

  func run() async -> [String: String]? {
    guard !inFlight, Date().timeIntervalSince(lastRelief) >= 5 else { return nil }
    inFlight = true
    lastRelief = Date()
    defer { inFlight = false }
    return await Task.detached(priority: .utility) {
      ModelRuntimeDiagnostics.relievePressure()
    }.value
  }
}
