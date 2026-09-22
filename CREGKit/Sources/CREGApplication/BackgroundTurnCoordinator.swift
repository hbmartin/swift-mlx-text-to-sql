#if os(iOS)
import BackgroundTasks
import CREGCore
import CREGFeatures
import CREGInference
import Foundation

extension Notification.Name {
  static let cregBackgroundTurnExpired = Notification.Name(
    "CREG.BackgroundTurnExpired")
}

/// The only owner of continued-processing task objects. Registration is
/// wildcard-based, while every direct user turn submits a concrete execution
/// ID. The coordinator is lock-protected because system launch and expiration
/// callbacks arrive on arbitrary queues.
final class BackgroundTurnCoordinator: @unchecked Sendable {
  static let shared = BackgroundTurnCoordinator()

  private let lock = NSLock()
  private let identifierPrefix: String
  private var registered = false
  private var requested: Set<UUID> = []
  private var active: [UUID: BGContinuedProcessingTask] = [:]
  private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

  private init() {
    identifierPrefix = (Bundle.main.bundleIdentifier ?? "com.creg.app")
      + ".continuedSQL."
    registered = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: identifierPrefix + "*",
      using: nil
    ) { [weak self] task in
      guard let task = task as? BGContinuedProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      self?.launched(task)
    }
  }

  var client: BackgroundTurnClient {
    BackgroundTurnClient(
      begin: { [self] id, directlyStarted in
        await begin(id, directlyStarted: directlyStarted)
      },
      progress: { [self] id, event in
        update(id, event: event)
      },
      finish: { [self] id, success in
        // Caller cancellation returns before a raw MLX operation necessarily
        // stops. Hold the scheduler barrier and any GPU grant until that
        // operation has settled, even when no background grant was issued.
        await LiveDependencies.serializer.waitUntilIdle()
        finish(id, success: success)
      })
  }

  private func begin(_ id: UUID, directlyStarted: Bool) async -> Bool {
    guard directlyStarted else { return false }
    let gpuSupported = BGTaskScheduler.supportedResources.contains(.gpu)
    let entitlementDeclared = Self.hasDeclaredGPUEntitlement
    guard registered, gpuSupported, entitlementDeclared else {
      recordState("unavailable", id: id, details: [
        "registered": String(registered),
        "gpu_supported": String(gpuSupported),
        "entitlement_declared": String(entitlementDeclared),
      ])
      return false
    }

    let identifier = identifierPrefix + id.uuidString
    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier,
      title: "CREG answer",
      subtitle: "Analyzing your portfolio question")
    request.strategy = .fail
    request.requiredResources = .gpu
    _ = lock.withLock { requested.insert(id) }
    do {
      try await BGTaskScheduler.shared.submitTaskRequest(request)
    } catch {
      let failure = error as NSError
      recordState("submission_failed", id: id, details: [
        "error_domain": failure.domain,
        "error_code": String(failure.code),
      ])
      finish(id, success: false)
      return false
    }
    recordState("submitted", id: id)
    return await withCheckedContinuation { continuation in
      let alreadyLaunched = lock.withLock { () -> Bool in
        if active[id] != nil { return true }
        waiters[id] = continuation
        return false
      }
      if alreadyLaunched {
        continuation.resume(returning: true)
      } else {
        Task { [self] in
          try? await Task.sleep(for: .seconds(2))
          timeOutStart(id)
        }
      }
    }
  }

  private func launched(_ task: BGContinuedProcessingTask) {
    guard let id = UUID(uuidString: String(task.identifier.suffix(36))) else {
      task.setTaskCompleted(success: false)
      return
    }
    let launch = lock.withLock { () -> (Bool, CheckedContinuation<Bool, Never>?) in
      guard requested.contains(id) else { return (false, nil) }
      active[id] = task
      return (true, waiters.removeValue(forKey: id))
    }
    guard launch.0 else {
      task.setTaskCompleted(success: false)
      return
    }
    task.progress.totalUnitCount = 100
    task.progress.completedUnitCount = 5
    task.expirationHandler = { [weak self] in self?.expired(id) }
    recordState("running", id: id)
    launch.1?.resume(returning: true)
  }

  private func expired(_ id: UUID) {
    recordState("expired_ambiguous", id: id)
    NotificationCenter.default.post(
      name: .cregBackgroundTurnExpired, object: id)
  }

  private func timeOutStart(_ id: UUID) {
    let waiter = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
      guard active[id] == nil else { return nil }
      requested.remove(id)
      return waiters.removeValue(forKey: id)
    }
    if let waiter {
      recordState("launch_timeout", id: id)
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:
        identifierPrefix + id.uuidString)
      waiter.resume(returning: false)
    }
  }

  private func update(_ id: UUID, event: PipelineEvent) {
    guard let task = lock.withLock({ active[id] }) else { return }
    let progress: Int64
    switch event {
    case .turnStarted: progress = 5
    case .questionResolved: progress = 15
    case .gateFinished: progress = 20
    case .generationStarted: progress = 30
    case .generationFinished: progress = 50
    case .validationFinished: progress = 65
    case .executionFinished, .preparedResultReady: progress = 75
    case .groundingFinished: progress = 82
    case .narrationStarted: progress = 88
    case .narrationFinished: progress = 96
    case .turnFinished: progress = 100
    default: return
    }
    task.progress.completedUnitCount = max(
      task.progress.completedUnitCount, progress)
  }

  private func finish(_ id: UUID, success: Bool) {
    let released = lock.withLock {
      requested.remove(id)
      return (active.removeValue(forKey: id), waiters.removeValue(forKey: id))
    }
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:
      identifierPrefix + id.uuidString)
    released.1?.resume(returning: false)
    released.0?.setTaskCompleted(success: success)
    if released.0 != nil || released.1 != nil {
      recordState(success ? "completed" : "interrupted", id: id)
    }
  }

  private func recordState(
    _ state: String, id: UUID,
    details: [String: String] = [:]
  ) {
    let context = ModelRuntimeDiagnostics.memoryContext(prefix: "background")
      .merging(details.merging([
        "state": state, "execution_id": id.uuidString,
      ]) { _, new in new }) { _, new in new }
    LiveDependencies.diagnostics.info(
      category: .inference,
      code: "background_task_state",
      summary: "A continued-processing task changed state.",
      context: context)
  }

  private static var hasDeclaredGPUEntitlement: Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    // iOS does not expose a public SecTask self-entitlement query. This
    // signed Info.plist marker is a build contract, not the final authority:
    // the scheduler rejects a missing signed entitlement, and only its
    // launched task authorizes GPU work after deactivation.
    return Bundle.main.object(forInfoDictionaryKey: "CREGBackgroundGPUAccess")
      as? Bool == true
    #endif
  }
}
#endif
