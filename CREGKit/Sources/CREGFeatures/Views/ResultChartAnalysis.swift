import AutoTableCharts
import AutoTableChartsUI
import CREGEngine
import Combine
import ComposableArchitecture
import Foundation

/// The single app-owned package cache shared by independent preview and viewer sessions.
struct CREGChartAnalysisClient: Sendable {
  static let maximumRetainedCost = 32 * 1_024 * 1_024
  static let configuration = AutoChartAnalyzerConfiguration(
    tables: .init(maximumEntries: 8),
    analyses: .init(maximumEntries: 64),
    preparedCharts: .init(maximumEntries: 16),
    maximumRetainedCost: maximumRetainedCost)

  static let live = CREGChartAnalysisClient(
    cache: AutoChartCache(configuration: configuration))

  let cache: AutoChartCache
  private let failures: ChartFailureStore

  init(cache: AutoChartCache) {
    self.cache = cache
    self.failures = ChartFailureStore()
  }

  @MainActor
  func makeSession() -> AutoChartSession<Int> {
    AutoChartSession(cache: cache)
  }

  func cachedAnalysis(
    for request: AutoChartRequest<Int>
  ) -> AutoChartAnalysis<Int>? {
    cache.completedAnalysis(for: request.id)
  }

  func requestConstructionFailure(
    inputIdentity: CREGChartInputIdentity,
    kind: AutoChartFailureKind,
    message: String
  ) -> AutoChartFailure {
    failures.requestConstructionFailure(
      inputIdentity: inputIdentity,
      kind: kind,
      message: message)
  }

  func claimFailureEpisode(_ failure: AutoChartFailure) -> Bool {
    failures.claim(failure.episodeID)
  }

  func trimToMinimum() async {
    failures.removeAll()
    await cache.trim(to: .minimum)
  }

  var cacheStatistics: AutoChartCacheStatistics {
    get async { await cache.statistics() }
  }
}

/// Stable, inexpensive identity for one view-owned chart request. SwiftUI can
/// use this as a task key without rebuilding the full chart dataset.
struct CREGChartInputIdentity: Hashable, Sendable {
  var resultFingerprint: String
  var dataIdentity: String?
  var sql: String
  var question: String?
}

/// Lazily retained by `StateObject`, so the package request and actor-backed
/// session are constructed once for a SwiftUI view identity rather than once
/// for every transient View value.
@MainActor
final class CREGChartSessionOwner: ObservableObject {
  private let client: CREGChartAnalysisClient
  let session: AutoChartSession<Int>
  @Published private(set) var inputIdentity: CREGChartInputIdentity
  @Published private var request: AutoChartRequest<Int>?
  @Published private var requestFailure: AutoChartFailure?

  init(
    client: CREGChartAnalysisClient,
    inputIdentity: CREGChartInputIdentity,
    result: QueryResult
  ) {
    self.client = client
    self.session = client.makeSession()
    self.inputIdentity = inputIdentity
    let setup = Self.makeRequest(
      client: client,
      result: result,
      inputIdentity: inputIdentity)
    self.request = setup.request
    self.requestFailure = setup.failure
  }

  func load(
    result: QueryResult,
    inputIdentity: CREGChartInputIdentity,
    preference: AutoChartPreference
  ) {
    if inputIdentity != self.inputIdentity {
      session.cancel()
      session.selection.removeAll()
      let setup = Self.makeRequest(
        client: client,
        result: result,
        inputIdentity: inputIdentity)
      self.request = setup.request
      self.requestFailure = setup.failure
      self.inputIdentity = inputIdentity
    }
    guard let request else { return }
    session.load(
      request,
      preference: preference,
      preparation: .preferredOrPrimary,
      presentationContext: .init(identity: "creg-v3"),
      formatters: CREGChartAdapter.formatters,
      textResolver: CREGChartAdapter.textResolver)
  }

  private func cachedAnalysis() -> AutoChartAnalysis<Int>? {
    request.flatMap { client.cachedAnalysis(for: $0) }
  }

  func analysis(
    for inputIdentity: CREGChartInputIdentity
  ) -> AutoChartAnalysis<Int>? {
    guard self.inputIdentity == inputIdentity else { return nil }
    return switch session.state {
    case .preparing(let analysis, _), .ready(let analysis, _),
      .fallback(let analysis, _):
      analysis
    case .idle, .analyzing, .failed:
      cachedAnalysis()
    }
  }

  func failure(
    for inputIdentity: CREGChartInputIdentity
  ) -> AutoChartFailure? {
    guard self.inputIdentity == inputIdentity else { return nil }
    if case .failed(let failure) = session.state { return failure }
    return requestFailure
  }

  func setPreferenceIfNeeded(_ preference: AutoChartPreference) {
    if session.preference != preference {
      session.setPreference(preference)
    }
  }

  /// Begins one retry attempt, optionally changing the preference as part of
  /// that same attempt. `AutoChartSession.setPreference` itself starts work, so
  /// calling it immediately before `retry()` would start and cancel two tasks.
  func retry(preference: AutoChartPreference? = nil) {
    guard let preference else {
      session.retry()
      return
    }
    guard let request else {
      session.setPreference(preference)
      return
    }
    session.selection.removeAll()
    client.cache.beginRetry(for: request.id)
    session.setPreference(preference)
  }

  func recordFailure(
    _ failure: AutoChartFailure,
    diagnostics: DiagnosticsClient
  ) {
    recordChartFailure(
      failure,
      chartAnalysis: client,
      diagnostics: diagnostics)
  }

  private static func makeRequest(
    client: CREGChartAnalysisClient,
    result: QueryResult,
    inputIdentity: CREGChartInputIdentity
  ) -> (request: AutoChartRequest<Int>?, failure: AutoChartFailure?) {
    do {
      let request = try CREGChartAdapter.analysisRequest(
        result: result,
        sql: inputIdentity.sql,
        question: inputIdentity.question,
        resultFingerprint: inputIdentity.resultFingerprint,
        dataIdentity: inputIdentity.dataIdentity)
      return (request, nil)
    } catch {
      let kind: AutoChartFailureKind =
        error is AutoChartDatasetError ? .invalidData : .internalFailure
      return (
        nil,
        client.requestConstructionFailure(
          inputIdentity: inputIdentity,
          kind: kind,
          message: String(describing: error)))
    }
  }
}

/// A bounded process-local ledger. The package intentionally shares an episode
/// ID across sessions for the same failure; CREG records that episode once even
/// when preview and viewer surfaces observe it independently.
private final class ChartFailureStore: @unchecked Sendable {
  private struct RequestConstructionKey: Hashable {
    var inputIdentity: CREGChartInputIdentity
    var kind: AutoChartFailureKind
    var message: String
  }

  private static let maximumEntries = 1_024
  private let lock = NSLock()
  private var episodeIDs: Set<UUID> = []
  private var insertionOrder: [UUID] = []
  private var requestConstructionFailures: [RequestConstructionKey: AutoChartFailure] = [:]
  private var requestConstructionOrder: [RequestConstructionKey] = []

  func claim(_ episodeID: UUID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard episodeIDs.insert(episodeID).inserted else { return false }
    insertionOrder.append(episodeID)
    if insertionOrder.count > Self.maximumEntries {
      episodeIDs.remove(insertionOrder.removeFirst())
    }
    return true
  }

  func requestConstructionFailure(
    inputIdentity: CREGChartInputIdentity,
    kind: AutoChartFailureKind,
    message: String
  ) -> AutoChartFailure {
    lock.lock()
    defer { lock.unlock() }
    let key = RequestConstructionKey(
      inputIdentity: inputIdentity,
      kind: kind,
      message: message)
    if let failure = requestConstructionFailures[key] { return failure }
    let failure = AutoChartFailure(
      stage: .materialization,
      kind: kind,
      isRetryable: false,
      diagnosticID: "ATC.materialization.\(kind.rawValue)",
      message: message)
    requestConstructionFailures[key] = failure
    requestConstructionOrder.append(key)
    if requestConstructionOrder.count > Self.maximumEntries {
      requestConstructionFailures.removeValue(
        forKey: requestConstructionOrder.removeFirst())
    }
    return failure
  }

  func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    episodeIDs.removeAll(keepingCapacity: false)
    insertionOrder.removeAll(keepingCapacity: false)
    requestConstructionFailures.removeAll(keepingCapacity: false)
    requestConstructionOrder.removeAll(keepingCapacity: false)
  }
}

extension CREGChartAnalysisClient: DependencyKey {
  static let liveValue = CREGChartAnalysisClient.live
  static var testValue: CREGChartAnalysisClient {
    CREGChartAnalysisClient(cache: AutoChartCache(configuration: .uncached))
  }
}

extension DependencyValues {
  var chartAnalysis: CREGChartAnalysisClient {
    get { self[CREGChartAnalysisClient.self] }
    set { self[CREGChartAnalysisClient.self] = newValue }
  }
}

func recordChartFailure(
  _ failure: AutoChartFailure,
  chartAnalysis: CREGChartAnalysisClient,
  diagnostics: DiagnosticsClient
) {
  guard chartAnalysis.claimFailureEpisode(failure) else { return }
  diagnostics.record(
    DiagnosticEvent(
      level: .error,
      category: .presentation,
      code: failure.diagnosticID,
      summary: "Chart presentation failed.",
      details: failure.message,
      context: [
        // Compact UUID form remains a stable episode token without matching
        // the diagnostics scrubber's user-identifier UUID pattern.
        "episode_id": failure.episodeID.uuidString.lowercased()
          .replacingOccurrences(of: "-", with: ""),
        "stage": failure.stage.rawValue,
        "kind": failure.kind.rawValue,
      ]))
}
