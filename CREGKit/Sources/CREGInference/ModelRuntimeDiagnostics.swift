import CREGCore
import Foundation
import MLX

public enum ModelRuntimeDiagnostics {
  public static func memoryContext(prefix: String = "memory") -> [String: String] {
    let snapshot = Memory.snapshot()
    return [
      "\(prefix)_active_mb": megabytes(snapshot.activeMemory),
      "\(prefix)_cache_mb": megabytes(snapshot.cacheMemory),
      "\(prefix)_peak_mb": megabytes(snapshot.peakMemory),
    ]
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
}
