import CREGEngine
import ComposableArchitecture
import Foundation

// MARK: - Dependency registrations

extension QueryPipeline: DependencyKey {
  public static var testValue: QueryPipeline {
    QueryPipeline { _, _ in AsyncStream { $0.finish() } }
  }

  public static var liveValue: QueryPipeline { testValue }
}

extension HistoryClient: DependencyKey {
  public static var testValue: HistoryClient { .noop() }
  public static var liveValue: HistoryClient { testValue }
}

extension SupportBundleClient: DependencyKey {
  public static var testValue: SupportBundleClient { .noop }
  public static var liveValue: SupportBundleClient { .live() }
}

extension FMStatusClient: DependencyKey {
  public static var testValue: FMStatusClient {
    FMStatusClient(availability: { .available })
  }

  public static var liveValue: FMStatusClient { .live() }
}

extension DependencyValues {
  public var queryPipeline: QueryPipeline {
    get { self[QueryPipeline.self] }
    set { self[QueryPipeline.self] = newValue }
  }

  public var historyClient: HistoryClient {
    get { self[HistoryClient.self] }
    set { self[HistoryClient.self] = newValue }
  }

  public var readAloud: ReadAloudClient {
    get { self[ReadAloudClient.self] }
    set { self[ReadAloudClient.self] = newValue }
  }

  public var haptics: HapticsClient {
    get { self[HapticsClient.self] }
    set { self[HapticsClient.self] = newValue }
  }

  public var supportBundle: SupportBundleClient {
    get { self[SupportBundleClient.self] }
    set { self[SupportBundleClient.self] = newValue }
  }

  public var fmStatus: FMStatusClient {
    get { self[FMStatusClient.self] }
    set { self[FMStatusClient.self] = newValue }
  }

  public var appIcon: AppIconClient {
    get { self[AppIconClient.self] }
    set { self[AppIconClient.self] = newValue }
  }
}
