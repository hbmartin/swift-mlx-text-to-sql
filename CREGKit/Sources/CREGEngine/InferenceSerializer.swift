/// Owns every model call — Apple FM and the bundled MLX model alike — and
/// guarantees no two inferences ever overlap, so active-inference peak memory
/// is max(FM, bundled), not the sum. See PRD §7.1.
///
/// Actors are reentrant, so a plain actor method would interleave awaited
/// operations; this instead chains each operation onto the previous one's
/// completion, giving strict arrival-order FIFO execution.
public actor InferenceSerializer {
  private var tail: Task<Void, Never>?

  public init() {}

  public func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let previous = tail
    let task = Task<T, Error> {
      await previous?.value
      return try await operation()
    }
    tail = Task { _ = try? await task.value }
    return try await task.value
  }
}
