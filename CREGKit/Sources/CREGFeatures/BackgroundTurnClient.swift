import CREGEngine
import ComposableArchitecture
import Foundation

/// The platform BGContinuedProcessingTask boundary. A successful `begin`
/// means the system has actually launched the task, not just accepted a
/// request. Without that active GPU grant the reducer cancels on background entry.
public struct BackgroundTurnClient: Sendable {
  public var begin: @Sendable (_ executionID: UUID, _ directlyUserStarted: Bool)
    async -> Bool
  public var progress: @Sendable (_ executionID: UUID, _ event: PipelineEvent)
    async -> Void
  public var finish: @Sendable (_ executionID: UUID, _ success: Bool)
    async -> Void

  public init(
    begin: @escaping @Sendable (UUID, Bool) async -> Bool,
    progress: @escaping @Sendable (UUID, PipelineEvent) async -> Void,
    finish: @escaping @Sendable (UUID, Bool) async -> Void
  ) {
    self.begin = begin
    self.progress = progress
    self.finish = finish
  }

  public static let unavailable = BackgroundTurnClient(
    begin: { _, _ in false },
    progress: { _, _ in },
    finish: { _, _ in })
}

extension BackgroundTurnClient: DependencyKey {
  public static var testValue: Self { .unavailable }
  public static var liveValue: Self { .unavailable }
}

extension DependencyValues {
  public var backgroundTurn: BackgroundTurnClient {
    get { self[BackgroundTurnClient.self] }
    set { self[BackgroundTurnClient.self] = newValue }
  }
}
