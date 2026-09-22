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

struct CREGChartMutationResult<Application> {
  var application: Application
  var commandRemainsCurrent: Bool
}

enum CREGChartLoadApplication: Hashable, Sendable {
  case noRequest
  case started
  case superseded
}

/// Lazily retained by `StateObject`, so the package request and actor-backed
/// session are constructed once for a SwiftUI view identity rather than once
/// for every transient View value.
@MainActor
final class CREGChartSessionOwner: ObservableObject {
  typealias RequestFactory = (
    CREGChartAnalysisClient, QueryResult, CREGChartInputIdentity
  ) -> (request: AutoChartRequest<Int>?, failure: AutoChartFailure?)
  private let client: CREGChartAnalysisClient
  private let requestFactory: RequestFactory?
  private let preparationStrategy: AutoChartPreparationStrategy
  let session: AutoChartSession<Int>
  private(set) var inputIdentity: CREGChartInputIdentity
  /// App-level invalidation token for restoring chart selection after a
  /// lifecycle change that may clear or invalidate the package selection.
  @Published private(set) var selectionRestorationAttempt: UInt64 = 0
  private var request: AutoChartRequest<Int>?
  private var requestFailure: AutoChartFailure?
  private var commandRevision: UInt64 = 0
  private var loadRevision: UInt64 = 0
  private struct PickerMemoKey: Equatable {
    let analysisID: AutoChartAnalysisID
    let selectedRecommendationID: AutoChartRecommendationID?
  }
  private var pickerMemo: (key: PickerMemoKey, options: [AutoChartPickerOption])?

  init(
    client: CREGChartAnalysisClient,
    inputIdentity: CREGChartInputIdentity,
    result: QueryResult,
    preparation: AutoChartPreparationStrategy = .preferredOrPrimary,
    requestFactory: RequestFactory? = nil
  ) {
    self.client = client
    self.requestFactory = requestFactory
    self.preparationStrategy = preparation
    self.session = client.makeSession()
    self.inputIdentity = inputIdentity
    let setup =
      requestFactory?(client, result, inputIdentity)
      ?? Self.makeRequest(
        client: client,
        result: result,
        inputIdentity: inputIdentity)
    self.request = setup.request
    self.requestFailure = setup.failure
  }

  @discardableResult
  func load(
    result: QueryResult,
    inputIdentity: CREGChartInputIdentity,
    preference: ResultPresentationPreference,
    beforeRestart: (() -> Void)? = nil
  ) -> CREGChartMutationResult<CREGChartLoadApplication> {
    let commandRevision = beginCommand()
    self.loadRevision &+= 1
    let loadRevision = self.loadRevision
    let changesIdentity = inputIdentity != self.inputIdentity
    let setup: (request: AutoChartRequest<Int>?, failure: AutoChartFailure?)? =
      if changesIdentity {
        requestFactory?(client, result, inputIdentity)
          ?? Self.makeRequest(
            client: client,
            result: result,
            inputIdentity: inputIdentity)
      } else {
        nil
      }
    guard self.loadRevision == loadRevision else {
      return CREGChartMutationResult(
        application: .superseded,
        commandRemainsCurrent: false)
    }

    let hasRequestToLoad = changesIdentity
      ? setup?.request != nil
      : request != nil
    if session.hasRetainedRequest, hasRequestToLoad {
      requestSelectionRestoration(onRestart: beforeRestart)
      guard self.loadRevision == loadRevision else {
        return CREGChartMutationResult(
          application: .superseded,
          commandRemainsCurrent: false)
      }
    }

    if changesIdentity {
      session.unload()
      guard self.loadRevision == loadRevision else {
        return CREGChartMutationResult(
          application: .superseded,
          commandRemainsCurrent: false)
      }
      guard let setup else {
        preconditionFailure("An identity change requires staged request state.")
      }
      objectWillChange.send()
      pickerMemo = nil
      request = setup.request
      requestFailure = setup.failure
      self.inputIdentity = inputIdentity
    }

    guard self.loadRevision == loadRevision else {
      return CREGChartMutationResult(
        application: .superseded,
        commandRemainsCurrent: false)
    }
    let effectivePreference: AutoChartPreference
    if self.commandRevision == commandRevision {
      effectivePreference = preference.packagePreference
    } else {
      effectivePreference = session.preference
    }
    guard let request else {
      _ = applyPackagePreference(
        effectivePreference,
        onRestart: beforeRestart)
      return CREGChartMutationResult(
        application: .noRequest,
        commandRemainsCurrent: commandIsCurrent(
          commandRevision, preference: preference.packagePreference))
    }

    let packageCommandRevision = self.commandRevision
    var packageApplication = session.load(
      request,
      preference: effectivePreference,
      preparation: preparationStrategy,
      presentationContext: .init(identity: "creg-v3"),
      formatters: CREGChartAdapter.formatters,
      textResolver: CREGChartAdapter.textResolver)
    guard self.loadRevision == loadRevision else {
      return CREGChartMutationResult(
        application: .superseded,
        commandRemainsCurrent: false)
    }

    // A preference command may synchronously supersede the package load after
    // it has retained the new request. Re-run once with that newer preference
    // so the identity transition remains live without reviving stale intent.
    if packageApplication == .superseded,
      self.commandRevision != packageCommandRevision
    {
      packageApplication = session.load(
        request,
        preference: session.preference,
        preparation: preparationStrategy,
        presentationContext: .init(identity: "creg-v3"),
        formatters: CREGChartAdapter.formatters,
        textResolver: CREGChartAdapter.textResolver)
      guard self.loadRevision == loadRevision else {
        return CREGChartMutationResult(
          application: .superseded,
          commandRemainsCurrent: false)
      }
    }

    if self.commandRevision == commandRevision,
      session.preference != preference.packagePreference
    {
      _ = applyPackagePreference(
        preference.packagePreference,
        onRestart: beforeRestart)
    }
    let remainsCurrent = commandIsCurrent(
      commandRevision, preference: preference.packagePreference)
    let application: CREGChartLoadApplication =
      packageApplication == .started ? .started : .superseded
    return CREGChartMutationResult(
      application: application,
      commandRemainsCurrent: remainsCurrent)
  }

  private func beginCommand() -> UInt64 {
    commandRevision &+= 1
    return commandRevision
  }

  private func commandIsCurrent(
    _ revision: UInt64,
    preference: AutoChartPreference
  ) -> Bool {
    commandRevision == revision && session.preference == preference
  }

  private func requestSelectionRestoration(onRestart: (() -> Void)?) {
    selectionRestorationAttempt &+= 1
    onRestart?()
  }

  private func applyPackagePreference(
    _ preference: AutoChartPreference,
    onRestart: (() -> Void)?
  ) -> AutoChartPreferenceApplicationResult {
    let result = session.applyPreferenceResult(preference)
    if result.application == .startedReplacement || result.changesVisibleChart {
      requestSelectionRestoration(onRestart: onRestart)
    }
    return result
  }

  private func cachedAnalysis() -> AutoChartAnalysis<Int>? {
    request.flatMap { client.cachedAnalysis(for: $0) }
  }

  func analysis(
    for expectedInputIdentity: CREGChartInputIdentity
  ) -> AutoChartAnalysis<Int>? {
    guard inputIdentity == expectedInputIdentity else { return nil }
    return switch session.state {
    case .preparing(let analysis, _), .ready(let analysis, _),
      .fallback(let analysis, _):
      analysis
    case .idle, .analyzing, .failed:
      cachedAnalysis()
    }
  }

  func failure(
    for expectedInputIdentity: CREGChartInputIdentity
  ) -> AutoChartFailure? {
    guard inputIdentity == expectedInputIdentity else { return nil }
    if case .failed(let failure) = session.state { return failure }
    return requestFailure
  }

  func displayedMode(
    for expectedInputIdentity: CREGChartInputIdentity,
    fallback preference: ResultPresentationPreference
  ) -> ResultPresentationMode {
    guard inputIdentity == expectedInputIdentity else { return preference.mode }
    if case .idle = session.state { return preference.mode }
    if case .table = session.preference { return .table }
    return .chart
  }

  func displayedRecommendation(
    for expectedInputIdentity: CREGChartInputIdentity
  ) -> AutoChartRecommendation? {
    guard inputIdentity == expectedInputIdentity else { return nil }
    return session.currentRecommendation
  }

  func hasPendingChart(
    for expectedInputIdentity: CREGChartInputIdentity,
    analysis: AutoChartAnalysis<Int>?
  ) -> Bool {
    guard inputIdentity == expectedInputIdentity,
      session.preference != .table,
      let analysis,
      analysis.request == request?.id,
      analysis.cregRecommendationCatalog?.primary != nil
    else { return false }
    switch session.state {
    case .preparing, .ready, .analyzing: return true
    case .idle, .fallback, .failed: return false
    }
  }

  @discardableResult
  func setPreferenceIfNeeded(
    _ preference: ResultPresentationPreference,
    onRestart: (() -> Void)? = nil
  ) -> CREGChartMutationResult<AutoChartPreferenceApplication> {
    let revision = beginCommand()
    let previous = session.preference
    let packageResult = applyPackagePreference(
      preference.packagePreference,
      onRestart: onRestart)
    let remainsCurrent = commandIsCurrent(
      revision, preference: preference.packagePreference)
    if commandRevision == revision, !remainsCurrent {
      _ = applyPackagePreference(previous, onRestart: onRestart)
    }
    return CREGChartMutationResult(
      application: packageResult.application,
      commandRemainsCurrent: remainsCurrent)
  }

  /// Reconciles an already-authoritative persisted or bound preference.
  @discardableResult
  func synchronizePreference(
    _ preference: ResultPresentationPreference,
    onRestart: (() -> Void)? = nil
  ) -> CREGChartMutationResult<AutoChartPreferenceApplication> {
    let revision = beginCommand()
    let packageResult = applyPackagePreference(
      preference.packagePreference,
      onRestart: onRestart)
    return CREGChartMutationResult(
      application: packageResult.application,
      commandRemainsCurrent: commandIsCurrent(
        revision, preference: preference.packagePreference))
  }

  func pickerOptions(
    analysis: AutoChartAnalysis<Int>?,
    selectedRecommendation: AutoChartRecommendation?
  ) -> [AutoChartPickerOption] {
    guard let analysis, let catalog = analysis.cregRecommendationCatalog
    else { return [] }
    let key = PickerMemoKey(
      analysisID: analysis.id,
      selectedRecommendationID: selectedRecommendation?.id)
    if let pickerMemo, pickerMemo.key == key { return pickerMemo.options }
    let options = resultChartPickerOptions(
      catalog: catalog,
      selectedRecommendation: selectedRecommendation,
      resolver: CREGChartAdapter.textResolver)
    pickerMemo = (key, options)
    return options
  }

  /// Begins one retry attempt, optionally changing the preference atomically.
  /// The result distinguishes an absent request from synchronous supersession.
  @discardableResult
  func retry(
    preference: ResultPresentationPreference? = nil,
    beforeRestart: (() -> Void)? = nil
  ) -> CREGChartMutationResult<AutoChartRetryApplication> {
    let revision = beginCommand()
    let previous = session.preference
    let requestedPreference = preference?.packagePreference ?? previous
    let application = session.retry(preference: requestedPreference)
    if application != .noRequest {
      requestSelectionRestoration(onRestart: beforeRestart)
    }
    let remainsCurrent = application == .started
      && commandIsCurrent(revision, preference: requestedPreference)
    if commandRevision == revision, !remainsCurrent,
      session.preference != previous
    {
      _ = applyPackagePreference(previous, onRestart: beforeRestart)
    }
    return CREGChartMutationResult(
      application: application,
      commandRemainsCurrent: remainsCurrent)
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
}

extension AutoChartAnalysis {
  var cregRecommendationCatalog: AutoChartRecommendationCatalog? {
    guard case .charts(let catalog) = outcome else { return nil }
    return catalog
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
