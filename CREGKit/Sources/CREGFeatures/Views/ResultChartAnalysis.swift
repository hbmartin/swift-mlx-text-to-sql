import AutoTableCharts
import CREGEngine
import ComposableArchitecture
import Foundation

/// The one app-owned chart analysis service. Its fixed memory budget is split
/// between the analyzer's reusable work and synchronous first-frame snapshots.
struct CREGChartAnalysisClient: Sendable {
  /// One app-wide ceiling across both cache owners. The analyzer gets most
  /// of the budget; the synchronous warm-start LRU gets the remainder.
  static let maximumRetainedCost = 32 * 1_024 * 1_024
  static let snapshotMaximumRetainedCost = 8 * 1_024 * 1_024
  static let configuration = AutoChartAnalyzerConfiguration(
    tables: .init(maximumEntries: 8),
    analyses: .init(maximumEntries: 64),
    preparedCharts: .init(maximumEntries: 16),
    maximumRetainedCost:
      maximumRetainedCost - snapshotMaximumRetainedCost)

  static let live = CREGChartAnalysisClient(
    analyzer: AutoChartAnalyzer(configuration: configuration))

  let analyzer: AutoChartAnalyzer
  let snapshots: ChartAnalysisSnapshotStore
  fileprivate let failureDiagnostics = ChartFailureDiagnosticStore()

  init(
    analyzer: AutoChartAnalyzer,
    snapshots: ChartAnalysisSnapshotStore = ChartAnalysisSnapshotStore()
  ) {
    self.analyzer = analyzer
    self.snapshots = snapshots
  }

  func analyze(
    result: QueryResult,
    sql: String,
    question: String?,
    resultFingerprint: String? = nil,
    dataIdentity: String? = nil
  ) async throws -> AutoChartAnalysis<Int> {
    let input = try CREGChartAdapter.analysisInput(
      result: result,
      sql: sql,
      question: question,
      resultFingerprint: resultFingerprint,
      dataIdentity: dataIdentity)
    let analysis = try await analyzer.analyze(
      input.dataset, context: input.context)
    if let dataIdentity, let resultFingerprint {
      snapshots.store(
        analysis,
        identity: dataIdentity,
        revision: CREGChartAdapter.dataKeyRevision(
          resultFingerprint: resultFingerprint, sql: sql),
        contextKey: ChartAnalysisSnapshotContextKey(question: question),
        retainedCost: Self.estimatedSnapshotCost(
          result: result, analysis: analysis))
    }
    return analysis
  }

  /// Synchronous read of a finished analysis, so a transcript cell re-created
  /// by the lazy list can render its chart on first frame instead of paying
  /// the dataset rebuild and analyzer round-trip again.
  func cachedAnalysis(
    resultFingerprint: String,
    sql: String,
    question: String?,
    dataIdentity: String
  ) -> AutoChartAnalysis<Int>? {
    snapshots.analysis(
      identity: dataIdentity,
      revision: CREGChartAdapter.dataKeyRevision(
        resultFingerprint: resultFingerprint, sql: sql),
      contextKey: ChartAnalysisSnapshotContextKey(question: question))
  }

  func trimToMinimum() async {
    snapshots.trimToMinimum()
    await analyzer.trim(to: .minimum)
  }

  var cacheStatistics: AutoChartCacheStatistics {
    get async { await analyzer.cacheStatistics }
  }

  var snapshotStatistics: ChartAnalysisSnapshotStore.Statistics {
    snapshots.statistics
  }

  /// A conservative retained-cost estimate for the graph reachable from a
  /// finished analysis. The package's exact prepared-source cost is private,
  /// so this mirrors its per-column/row/cell accounting and adds headroom
  /// for public analysis metadata and prepared marks. The walk touches every
  /// cell, so `store` evaluates it lazily — only when the snapshot is new.
  private static func estimatedSnapshotCost(
    result: QueryResult,
    analysis: AutoChartAnalysis<Int>
  ) -> Int {
    var cost = 1_024
    for column in result.columns {
      cost += 1_024 + column.utf8.count * 2
    }
    for row in result.rows {
      cost += 256
      for value in row {
        cost += 192
        switch value {
        case .text(let text):
          cost += text.utf8.count * 2
        case .blob(let data):
          cost += data.count * 2
        case .null, .integer, .real:
          cost += 16
        }
      }
    }
    cost += analysis.columnProfiles.count * 512
    cost += analysis.diagnostics.count * 1_024
    switch analysis.outcome {
    case .charts(let recommendations):
      cost += recommendations.count * 2_048
    case .tableFallback:
      cost += 1_024
    }
    cost += (analysis.primaryChart?.marks.count ?? 0) * 384
    return cost
  }
}

/// A process-local ledger of live chart-failure episodes already emitted to
/// diagnostics. The client is shared by independently owned preview/viewer
/// loaders and by replacement loaders created when SwiftUI recycles a row, so
/// this is the narrowest owner that can distinguish an incidental repeat from
/// a genuinely new failure episode. Entries disappear with their last claim,
/// naturally bounding the ledger by the number of live failed loaders.
private final class ChartFailureDiagnosticStore: @unchecked Sendable {
  struct Identity: Hashable, Sendable {
    private var requestDigest: Int
    private var recommendationDigest: Int?
    private var stage: ResultChartLoader.Failure.Stage
    private var kind: ResultChartLoader.Failure.Kind
    private var errorDigest: Int

    init(
      requestKey: ResultChartLoader.Request.Key,
      recommendationID: AutoChartRecommendationID?,
      failure: ResultChartLoader.Failure
    ) {
      requestDigest = Self.digest(requestKey)
      recommendationDigest = recommendationID.map(Self.digest)
      stage = failure.stage
      kind = failure.kind
      errorDigest = Self.digest(failure.diagnosticIdentity)
    }

    /// The ledger never retains questions, SQL, recommendation identifiers, or
    /// diagnostic details. Swift's process-seeded hash is sufficient because
    /// deduplication is deliberately process-local.
    private static func digest<Value: Hashable>(_ value: Value) -> Int {
      var hasher = Hasher()
      hasher.combine(value)
      return hasher.finalize()
    }
  }

  final class Claim: @unchecked Sendable {
    private let store: ChartFailureDiagnosticStore
    private let identity: Identity
    private let episode: UInt64
    private let token: UInt64

    fileprivate init(
      store: ChartFailureDiagnosticStore,
      identity: Identity,
      episode: UInt64,
      token: UInt64
    ) {
      self.store = store
      self.identity = identity
      self.episode = episode
      self.token = token
    }

    deinit {
      store.release(identity: identity, episode: episode, token: token)
    }
  }

  struct ClaimResult: Sendable {
    var claim: Claim
    var shouldRecord: Bool
  }

  private struct Entry {
    var currentEpisode: UInt64
    var claimTokensByEpisode: [UInt64: Set<UInt64>]
  }

  private let lock = NSLock()
  private var recorded: [Identity: Entry] = [:]
  private var nextEpisode: UInt64 = 0
  private var nextClaimToken: UInt64 = 0

  /// Claims a logical failure episode. Incidental repeats join the current
  /// episode, while an explicit retry becomes current even if another surface
  /// still displays the preceding failure. Every live episode remains tracked,
  /// so releasing the retried surface falls back to the newest remaining live
  /// episode instead of making an identical failure recordable again.
  func claim(
    _ identity: Identity,
    startsNewEpisode: Bool
  ) -> ClaimResult {
    lock.lock()
    defer { lock.unlock() }
    nextClaimToken &+= 1
    let token = nextClaimToken
    if var entry = recorded[identity], !startsNewEpisode {
      entry.claimTokensByEpisode[entry.currentEpisode, default: []]
        .insert(token)
      recorded[identity] = entry
      return ClaimResult(
        claim: Claim(
          store: self,
          identity: identity,
          episode: entry.currentEpisode,
          token: token),
        shouldRecord: false)
    }
    nextEpisode &+= 1
    let episode = nextEpisode
    var claimTokensByEpisode =
      recorded[identity]?.claimTokensByEpisode ?? [:]
    claimTokensByEpisode[episode] = [token]
    recorded[identity] = Entry(
      currentEpisode: episode,
      claimTokensByEpisode: claimTokensByEpisode)
    return ClaimResult(
      claim: Claim(
        store: self,
        identity: identity,
        episode: episode,
        token: token),
      shouldRecord: true)
  }

  private func release(
    identity: Identity,
    episode: UInt64,
    token: UInt64
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard var entry = recorded[identity],
      var claimTokens = entry.claimTokensByEpisode[episode],
      claimTokens.remove(token) != nil
    else {
      return
    }
    if claimTokens.isEmpty {
      entry.claimTokensByEpisode.removeValue(forKey: episode)
    } else {
      entry.claimTokensByEpisode[episode] = claimTokens
    }
    guard !entry.claimTokensByEpisode.isEmpty else {
      recorded.removeValue(forKey: identity)
      return
    }
    if entry.claimTokensByEpisode[entry.currentEpisode] == nil,
      let newestLiveEpisode = entry.claimTokensByEpisode.keys.max()
    {
      entry.currentEpisode = newestLiveEpisode
    }
    recorded[identity] = entry
  }
}

/// The inexpensive source identity for `AutoChartContext`. The snapshot
/// revision already covers SQL, leaving the question as the only additional
/// input to CREG's deterministic goal and title derivation.
struct ChartAnalysisSnapshotContextKey: Hashable, Sendable {
  var question: String?
}

/// LRU snapshots of finished analyses keyed by chart-data identity. A
/// revision mismatch (same message, different result bytes or SQL) misses
/// rather than serving a stale analysis.
final class ChartAnalysisSnapshotStore: @unchecked Sendable {
  struct Statistics: Equatable, Sendable {
    var entries = 0
    var retainedCost = 0
    var hits = 0
    var misses = 0
    var evictions = 0
  }

  /// A fresh zero-capacity store per access. A shared singleton would
  /// accumulate hit/miss statistics across parallel tests, making any future
  /// counter assertion order-dependent.
  static var uncached: ChartAnalysisSnapshotStore {
    ChartAnalysisSnapshotStore(capacity: 0, maximumRetainedCost: 0)
  }

  private struct Entry {
    var revision: String
    var contextKey: ChartAnalysisSnapshotContextKey
    var analysis: AutoChartAnalysis<Int>
    var retainedCost: Int
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var recency: [String] = []
  private let capacity: Int
  private let maximumRetainedCost: Int
  private var retainedCost = 0
  private var hits = 0
  private var misses = 0
  private var evictions = 0

  init(
    capacity: Int = 24,
    maximumRetainedCost: Int = CREGChartAnalysisClient
      .snapshotMaximumRetainedCost
  ) {
    self.capacity = max(0, capacity)
    self.maximumRetainedCost = max(0, maximumRetainedCost)
  }

  func analysis(
    identity: String,
    revision: String,
    contextKey: ChartAnalysisSnapshotContextKey
  ) -> AutoChartAnalysis<Int>? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = entries[identity], entry.revision == revision else {
      misses += 1
      return nil
    }
    guard entry.contextKey == contextKey else {
      // A superseded SwiftUI surface can still probe its old question while a
      // newer surface owns the current snapshot. Reads must remain
      // non-destructive so that obsolete probes cannot evict the replacement.
      misses += 1
      return nil
    }
    hits += 1
    recency.removeAll { $0 == identity }
    recency.append(identity)
    return entry.analysis
  }

  func store(
    _ analysis: AutoChartAnalysis<Int>,
    identity: String,
    revision: String,
    contextKey: ChartAnalysisSnapshotContextKey,
    retainedCost: @autoclosure () -> Int
  ) {
    guard capacity > 0 else { return }
    lock.lock()
    if let existing = entries[identity],
      existing.revision == revision,
      existing.contextKey == contextKey
    {
      // The inline preview and the full-screen viewer analyze the same
      // message; an identical snapshot only needs its recency refreshed,
      // never a cost re-estimate.
      recency.removeAll { $0 == identity }
      recency.append(identity)
      lock.unlock()
      return
    }
    lock.unlock()
    // Evaluated outside the lock: the estimate walks every result cell and
    // must not block synchronous first-frame reads. A racing store of the
    // same identity is last-writer-wins.
    let cost = max(0, retainedCost())
    lock.lock()
    defer { lock.unlock() }
    if let previous = entries.removeValue(forKey: identity) {
      self.retainedCost -= previous.retainedCost
      recency.removeAll { $0 == identity }
    }
    entries[identity] = Entry(
      revision: revision,
      contextKey: contextKey,
      analysis: analysis,
      retainedCost: cost)
    self.retainedCost += cost
    recency.append(identity)
    // Budget pressure evicts older entries but never the snapshot just
    // stored: a single result larger than the whole budget keeps its warm
    // start as the sole resident — large results are exactly where
    // re-analysis hurts most — and the memory-warning trim still clears it.
    while recency.count > 1,
      recency.count > capacity || self.retainedCost > maximumRetainedCost
    {
      evictLeastRecent()
    }
  }

  var statistics: Statistics {
    lock.lock()
    defer { lock.unlock() }
    return Statistics(
      entries: entries.count,
      retainedCost: retainedCost,
      hits: hits,
      misses: misses,
      evictions: evictions)
  }

  /// Memory-pressure trims deliberately do not count as `evictions`: that
  /// counter measures LRU budget pressure, and conflating the two would make
  /// the cache read as thrashing after a few background cycles.
  func trimToMinimum() {
    lock.lock()
    defer { lock.unlock() }
    entries.removeAll()
    recency.removeAll()
    retainedCost = 0
  }

  func removeAll() {
    lock.lock()
    defer { lock.unlock() }
    entries.removeAll()
    recency.removeAll()
    retainedCost = 0
    hits = 0
    misses = 0
    evictions = 0
  }

  private func evictLeastRecent() {
    guard !recency.isEmpty else { return }
    let identity = recency.removeFirst()
    guard let removed = entries.removeValue(forKey: identity) else { return }
    retainedCost -= removed.retainedCost
    evictions += 1
  }
}

/// Identity of one SwiftUI chart-preparation task. Recommendation identity is
/// not sufficient on its own: replacement analyses can recommend the same
/// specification.
struct ResultChartPreparationTaskKey: Equatable {
  fileprivate var requestKey: ResultChartLoader.Request.Key?
  fileprivate var analysisGeneration: Int
  fileprivate var recommendationID: AutoChartRecommendationID?
  fileprivate var attempt: Int
}

/// Defers loader construction until SwiftUI reads the state owner retained for
/// this view identity. Recomputed view values create only this inexpensive
/// wrapper; discarded values never probe or resolve the warm-start snapshot.
/// The retained loader is keyed to its request so a replacement result can
/// synchronously adopt its own snapshot instead of inheriting an earlier
/// loader that has already consumed its one construction-time warm start.
/// Dependency clients are captured for this retained owner's lifetime; a view
/// that installs new overrides must also establish a new owner identity so the
/// loader and its lifecycle telemetry continue to use the same clients.
@MainActor
final class ResultChartLoaderOwner {
  typealias MakeLoader =
    @MainActor (
      ResultChartLoader.Request,
      AutoChartRecommendationID?,
      DiagnosticsClient
    ) -> ResultChartLoader

  private enum Source {
    case client(CREGChartAnalysisClient)
    case factory(MakeLoader)
  }

  private let source: Source
  let diagnostics: DiagnosticsClient
  private var storedLoader: ResultChartLoader?
  private var storedRequestKey: ResultChartLoader.Request.Key?

  init(
    client: CREGChartAnalysisClient,
    diagnostics: DiagnosticsClient
  ) {
    source = .client(client)
    self.diagnostics = diagnostics
  }

  init(
    diagnostics: DiagnosticsClient,
    makeLoader: @escaping MakeLoader
  ) {
    source = .factory(makeLoader)
    self.diagnostics = diagnostics
  }

  /// The first retained view value for a request supplies its authoritative
  /// warm start. Repeated reads reuse that loader; a replacement request gets a
  /// fresh loader whose synchronous snapshot and preferred chart are current.
  func loader(
    warmStart request: ResultChartLoader.Request,
    preferredSpecificationID: AutoChartRecommendationID?
  ) -> ResultChartLoader {
    if storedRequestKey == request.key, let storedLoader {
      return storedLoader
    }
    let loader =
      switch source {
      case .client(let client):
        ResultChartLoader(
          client: client,
          diagnostics: diagnostics,
          warmStart: request,
          preferredSpecificationID: preferredSpecificationID)
      case .factory(let makeLoader):
        makeLoader(request, preferredSpecificationID, diagnostics)
      }
    storedLoader = loader
    storedRequestKey = request.key
    return loader
  }
}

/// The chart-loading state machine used independently by the inline Result
/// Preview and full-screen Result Viewer. Views keep their own presentation
/// policy — what to select, when to fall back to the table, what to persist —
/// while each loader owns its surface's analyze/prepare mechanics. The shared
/// client snapshot lets equivalent inputs reuse finished analysis; synchronized
/// presentation inputs let the independent surfaces converge on the same
/// recommendation. A loader warm-starts from that snapshot so a re-created
/// transcript cell renders immediately instead of re-blanking into a spinner.
@MainActor
@Observable
final class ResultChartLoader {
  typealias AnalyzeChart =
    @Sendable (
      Request
    ) async throws -> AutoChartAnalysis<Int>
  typealias PrepareChart =
    @Sendable (
      AutoChartAnalysis<Int>, AutoChartRecommendationID
    ) async throws -> AutoChartPreparedChart<Int>

  struct Request: Sendable {
    struct Key: Hashable, Sendable {
      let resultFingerprint: String
      let dataIdentity: String?
      let sql: String
      let question: String?
    }

    let result: QueryResult
    let sql: String
    let question: String?
    let resultFingerprint: String
    let dataIdentity: String?

    var key: Key {
      Key(
        resultFingerprint: resultFingerprint,
        dataIdentity: dataIdentity,
        sql: sql,
        question: question)
    }
  }

  struct Failure: Equatable, Sendable {
    enum Kind: Hashable, Sendable {
      case invalidDataset
      case invalidSpecification
      case transient
    }

    enum Stage: Hashable, Sendable {
      case analysis
      case preparation
    }

    enum Retryability: Equatable, Sendable {
      case retryable
      case terminal
    }

    fileprivate struct DiagnosticIdentity: Hashable, Sendable {
      var typeName: String
      var domain: String
      var code: Int
    }

    let stage: Stage
    let kind: Kind
    let details: String
    fileprivate let diagnosticIdentity: DiagnosticIdentity

    var retryability: Retryability {
      switch kind {
      case .invalidDataset, .invalidSpecification:
        .terminal
      case .transient:
        .retryable
      }
    }

    init(_ error: any Error, stage: Stage) {
      self.stage = stage
      details = DiagnosticDetails.describe(error)
      let bridgedError = error as NSError
      diagnosticIdentity = DiagnosticIdentity(
        typeName: String(reflecting: type(of: error)),
        domain: bridgedError.domain,
        code: bridgedError.code)
      // These package errors describe deterministic contract violations. CREG's
      // current normalized dataset and generated-recommendation paths should
      // prevent them, but custom clients and future adapters must not present a
      // retry that cannot change the outcome.
      if error is AutoChartDatasetError {
        kind = .invalidDataset
      } else if error is AutoChartPreparationError {
        kind = .invalidSpecification
      } else {
        kind = .transient
      }
    }
  }

  enum Resolution {
    case resolved(
      AutoChartRecommendation,
      analysis: AutoChartAnalysis<Int>,
      defaultReason: AutoChartRecommendationResolution.DefaultReason?)
    case unavailable
    case failed(Failure)
  }

  private struct LoadedAnalysis {
    let key: Request.Key
    let value: AutoChartAnalysis<Int>
  }

  private struct FailedAnalysis {
    let key: Request.Key
    let failure: Failure
    let diagnosticClaim: ChartFailureDiagnosticStore.Claim
  }

  private struct FailedPreparation {
    let recommendationID: AutoChartRecommendationID
    let failure: Failure
    let diagnosticClaim: ChartFailureDiagnosticStore.Claim
  }

  private enum OwnedFailure {
    case analysis(FailedAnalysis)
    case preparation(FailedPreparation)

    var failure: Failure {
      switch self {
      case .analysis(let failedAnalysis):
        failedAnalysis.failure
      case .preparation(let failedPreparation):
        failedPreparation.failure
      }
    }
  }

  private struct PreparationFailureRetryKey: Equatable {
    let analysisGeneration: Int
    let recommendationID: AutoChartRecommendationID
  }

  private enum PreparationOutcome {
    case prepared(AutoChartPreparedChart<Int>)
    case failed(Failure)
  }

  private var loadedAnalysis: LoadedAnalysis?
  private var failedAnalysis: FailedAnalysis?
  private var activeRequestKey: Request.Key?
  private var currentRecommendation: AutoChartRecommendation?
  private var preparedChart: AutoChartPreparedChart<Int>?
  private var failedPreparation: FailedPreparation?
  private let analyzeChart: AnalyzeChart
  private let prepareChart: PrepareChart
  private let diagnostics: DiagnosticsClient
  private let failureDiagnostics: ChartFailureDiagnosticStore
  /// The recommendation the loader most recently resolved or was asked to
  /// prepare. A resolution change supersedes preparation still suspended for
  /// the previous recommendation, even when the analysis itself is reused.
  private var resolvedRecommendationID: AutoChartRecommendationID?
  /// Every started attempt supersedes earlier preparation calls, including
  /// calls for a different recommendation in the same analysis generation.
  private var preparationGeneration = 0
  /// Explicit retries re-key SwiftUI's preparation task even when the analysis
  /// and recommendation are unchanged.
  private var preparationAttempt = 0
  /// Explicit retries re-key SwiftUI's analysis task without changing the
  /// request or pin that determine the analysis result.
  private var analysisAttempt = 0
  /// The next committed analyzer failure belongs to a user-initiated retry, not
  /// the episode that may still be visible on another surface.
  private var nextAnalysisFailureStartsNewEpisode = false
  /// One explicitly retried preparation may start a fresh diagnostic episode.
  /// Loader-local generations avoid retaining the request's SQL or question;
  /// changing recommendations or requests abandons an unstarted retry intent.
  private var nextPreparationFailureStartsNewEpisode: PreparationFailureRetryKey?
  /// Identity of the analysis this loader currently owns. It prevents both a
  /// superseded analysis and a preparation suspended on its predecessor from
  /// committing after a newer request has taken ownership of the loader.
  private var analysisGeneration = 0

  init(
    client: CREGChartAnalysisClient,
    diagnostics: DiagnosticsClient,
    warmStart request: Request?,
    preferredSpecificationID: AutoChartRecommendationID? = nil,
    analyzeChart: AnalyzeChart? = nil,
    prepareChart: PrepareChart? = nil
  ) {
    activeRequestKey = request?.key
    self.diagnostics = diagnostics
    failureDiagnostics = client.failureDiagnostics
    self.analyzeChart =
      analyzeChart ?? { request in
        try await client.analyze(
          result: request.result,
          sql: request.sql,
          question: request.question,
          resultFingerprint: request.resultFingerprint,
          dataIdentity: request.dataIdentity)
      }
    self.prepareChart =
      prepareChart ?? { analysis, recommendationID in
        try await analysis.prepare(recommendationID)
      }
    guard
      let request,
      let dataIdentity = request.dataIdentity,
      let cached = client.cachedAnalysis(
        resultFingerprint: request.resultFingerprint,
        sql: request.sql,
        question: request.question,
        dataIdentity: dataIdentity)
    else { return }
    loadedAnalysis = LoadedAnalysis(key: request.key, value: cached)
    applyResolution(of: cached, preferred: preferredSpecificationID)
  }

  /// Analyzes (or reuses the warm-started analysis) and resolves the preferred
  /// specification. Returns nil when cancelled or superseded; analyzer failures
  /// remain explicit so the caller can record and apply their recovery policy.
  func analyze(
    _ request: Request,
    preferredSpecificationID: AutoChartRecommendationID?
  ) async -> Resolution? {
    synchronizeRequest(request.key)
    guard !Task.isCancelled else { return nil }
    if let failedAnalysis, failedAnalysis.key == request.key {
      return .failed(failedAnalysis.failure)
    }
    if let loadedAnalysis, loadedAnalysis.key == request.key {
      return applyResolution(
        of: loadedAnalysis.value,
        preferred: preferredSpecificationID)
    }

    clearFailedAnalysis()
    clearFailedPreparation()
    resolvedRecommendationID = nil
    currentRecommendation = nil
    loadedAnalysis = nil
    preparedChart = nil
    analysisGeneration += 1
    let requestGeneration = analysisGeneration
    let startsNewDiagnosticEpisode = nextAnalysisFailureStartsNewEpisode
    do {
      let loaded = try await analyzeChart(request)
      try Task.checkCancellation()
      guard requestGeneration == analysisGeneration else { return nil }
      nextAnalysisFailureStartsNewEpisode = false
      loadedAnalysis = LoadedAnalysis(key: request.key, value: loaded)
      return applyResolution(
        of: loaded,
        preferred: preferredSpecificationID)
    } catch {
      guard !Task.isCancelled, requestGeneration == analysisGeneration else {
        return nil
      }
      let failure = Failure(error, stage: .analysis)
      nextAnalysisFailureStartsNewEpisode = false
      commitFailureDiagnostic(
        failure,
        requestKey: request.key,
        recommendationID: nil,
        startsNewEpisode: startsNewDiagnosticEpisode
      ) { claim in
        failedAnalysis = FailedAnalysis(
          key: request.key,
          failure: failure,
          diagnosticClaim: claim)
      }
      return .failed(failure)
    }
  }

  func hasLoadedAnalysis(for key: Request.Key) -> Bool {
    loadedAnalysis(for: key) != nil
  }

  func analysis(for key: Request.Key) -> AutoChartAnalysis<Int>? {
    loadedAnalysis(for: key)?.value
  }

  func resolvedRecommendation(
    for key: Request.Key
  ) -> AutoChartRecommendation? {
    guard loadedAnalysis(for: key) != nil else { return nil }
    return currentRecommendation
  }

  /// The failure currently owned by this request and recommendation. Analysis
  /// failures do not require a recommendation; preparation failures must still
  /// belong to the loader's selected recommendation.
  func failure(
    for requestKey: Request.Key,
    recommendationID: AutoChartRecommendationID?
  ) -> Failure? {
    ownedFailure(
      for: requestKey,
      recommendationID: recommendationID
    )?.failure
  }

  /// Re-resolves the loaded immutable analysis and synchronizes every piece of
  /// recommendation-owned presentation state before a view observes the choice.
  func resolveLoadedRecommendation(
    for requestKey: Request.Key,
    preferredSpecificationID: AutoChartRecommendationID?
  ) -> Resolution? {
    guard let analysis = loadedAnalysis(for: requestKey)?.value else {
      return nil
    }
    return applyResolution(
      of: analysis, preferred: preferredSpecificationID)
  }

  /// Selects one recommendation from the currently loaded analysis and applies
  /// all recommendation-owned loader state. Rejecting IDs outside the loaded
  /// recommendation set keeps picker input from silently defaulting.
  func selectLoadedRecommendation(
    _ recommendationID: AutoChartRecommendationID,
    for requestKey: Request.Key
  ) -> Bool {
    guard let loadedAnalysis = loadedAnalysis(for: requestKey),
      case .charts(let recommendations) = loadedAnalysis.value.outcome,
      let recommendation = recommendations.first(where: {
        $0.id == recommendationID
      })
    else { return false }
    let analysis = loadedAnalysis.value

    _ = applyResolvedRecommendation(
      recommendation,
      analysis: analysis,
      defaultReason: nil)
    return true
  }

  /// SwiftUI can observe a new selection before its preparation task runs.
  /// Never expose a prepared chart belonging to the preceding recommendation
  /// during that interval. A matching chart remains usable while an incidental
  /// same-recommendation preparation is suspended, cancelled, or fails.
  func matchingPreparedChart(
    for recommendationID: AutoChartRecommendationID
  ) -> AutoChartPreparedChart<Int>? {
    guard preparedChart?.recommendation.id == recommendationID else {
      return nil
    }
    return preparedChart
  }

  /// Prepares the selected recommendation's chart, reusing the analysis's
  /// primary chart when it matches. Every started attempt supersedes earlier
  /// preparation calls; a retained failure suppresses incidental task restarts
  /// until an explicit retry clears it. Failure diagnostics are committed here
  /// so caller cancellation cannot separate state mutation from telemetry. A
  /// redundant failure never replaces an already prepared matching chart with
  /// recovery state.
  func prepareResolvedRecommendation(
    for requestKey: Request.Key
  ) async {
    guard activeRequestKey == requestKey else { return }
    guard !Task.isCancelled else { return }
    guard let chartAnalysis = loadedAnalysis(for: requestKey)?.value,
      let recommendation = currentRecommendation
    else {
      preparationGeneration += 1
      nextPreparationFailureStartsNewEpisode = nil
      clearFailedPreparation()
      preparedChart = nil
      return
    }
    guard failedPreparation?.recommendationID != recommendation.id else {
      return
    }
    preparationGeneration += 1
    let preparation = preparationGeneration
    let requestAnalysisGeneration = analysisGeneration
    let failureRetryKey = PreparationFailureRetryKey(
      analysisGeneration: requestAnalysisGeneration,
      recommendationID: recommendation.id)
    let startsNewDiagnosticEpisode =
      nextPreparationFailureStartsNewEpisode == failureRetryKey
    clearFailedPreparation()
    let outcome: PreparationOutcome
    if let primaryChart = chartAnalysis.primaryChart,
      primaryChart.recommendation.id == recommendation.id
    {
      outcome = .prepared(primaryChart)
    } else {
      do {
        let prepared = try await prepareChart(chartAnalysis, recommendation.id)
        outcome = .prepared(prepared)
      } catch {
        outcome = .failed(Failure(error, stage: .preparation))
      }
    }
    guard !Task.isCancelled,
      requestAnalysisGeneration == analysisGeneration,
      preparation == preparationGeneration,
      resolvedRecommendationID == recommendation.id
    else { return }
    if startsNewDiagnosticEpisode {
      nextPreparationFailureStartsNewEpisode = nil
    }
    switch outcome {
    case .prepared(let prepared):
      preparedChart = prepared
    case .failed(let failure):
      guard preparedChart?.recommendation.id != recommendation.id else {
        return
      }
      preparedChart = nil
      commitFailureDiagnostic(
        failure,
        requestKey: requestKey,
        recommendationID: recommendation.id,
        startsNewEpisode: startsNewDiagnosticEpisode
      ) { claim in
        failedPreparation = FailedPreparation(
          recommendationID: recommendation.id,
          failure: failure,
          diagnosticClaim: claim)
      }
    }
  }

  /// Identity used by both chart surfaces for their preparation task. Keeping
  /// the loader's generations private prevents either view from reimplementing
  /// only part of the selection and replacement-analysis contract.
  func preparationTaskKey(
    recommendationID: AutoChartRecommendationID?
  ) -> ResultChartPreparationTaskKey {
    ResultChartPreparationTaskKey(
      requestKey: activeRequestKey,
      analysisGeneration: analysisGeneration,
      recommendationID: recommendationID,
      attempt: preparationAttempt)
  }

  /// Identity used by both chart surfaces for their analysis task. The key
  /// keeps mode projection and explicit retry identity inside the loader rather
  /// than requiring SwiftUI call sites to reproduce either invariant.
  func analysisTaskKey(
    requestKey: Request.Key,
    preference: ResultPresentationPreference?
  ) -> ResultPresentationAnalysisTaskKey {
    ResultPresentationAnalysisTaskKey(
      chartRequest: requestKey,
      preference: preference,
      attempt: analysisAttempt)
  }

  /// Invalidates request-owned state as soon as a replacement request becomes
  /// authoritative, even if its SwiftUI analysis task is cancelled before it
  /// reaches the analyzer.
  func synchronizeRequest(_ requestKey: Request.Key) {
    guard activeRequestKey != requestKey else { return }
    clearFailedAnalysis()
    clearFailedPreparation()
    activeRequestKey = requestKey
    nextAnalysisFailureStartsNewEpisode = false
    nextPreparationFailureStartsNewEpisode = nil
    resolvedRecommendationID = nil
    currentRecommendation = nil
    loadedAnalysis = nil
    preparedChart = nil
    analysisGeneration += 1
    preparationGeneration += 1
  }

  /// Retries the current failure only when its typed policy permits it. Views
  /// use this single operation instead of reproducing analysis/preparation
  /// branching and accidentally exposing retries for terminal failures.
  @discardableResult
  func retryFailure(
    for requestKey: Request.Key,
    recommendationID: AutoChartRecommendationID?
  ) -> Bool {
    guard
      let ownedFailure = ownedFailure(
        for: requestKey,
        recommendationID: recommendationID),
      ownedFailure.failure.retryability == .retryable
    else { return false }
    switch ownedFailure {
    case .analysis:
      clearFailedAnalysis()
      nextAnalysisFailureStartsNewEpisode = true
      analysisAttempt += 1
    case .preparation(let failedPreparation):
      nextPreparationFailureStartsNewEpisode = PreparationFailureRetryKey(
        analysisGeneration: analysisGeneration,
        recommendationID: failedPreparation.recommendationID)
      clearFailedPreparation()
      preparationGeneration += 1
      preparationAttempt += 1
    }
    return true
  }

  @discardableResult
  private func applyResolution(
    of loaded: AutoChartAnalysis<Int>,
    preferred: AutoChartRecommendationID?
  ) -> Resolution {
    switch loaded.resolve(preferred) {
    case .exact(let recommendation):
      return applyResolvedRecommendation(
        recommendation,
        analysis: loaded,
        defaultReason: nil)
    case .defaulted(let recommendation, let reason):
      return applyResolvedRecommendation(
        recommendation,
        analysis: loaded,
        defaultReason: reason)
    case .unavailable:
      resolvedRecommendationID = nil
      currentRecommendation = nil
      preparedChart = nil
      nextPreparationFailureStartsNewEpisode = nil
      clearFailedPreparation()
      return .unavailable
    }
  }

  private func applyResolvedRecommendation(
    _ recommendation: AutoChartRecommendation,
    analysis resolvedAnalysis: AutoChartAnalysis<Int>,
    defaultReason: AutoChartRecommendationResolution.DefaultReason?
  ) -> Resolution {
    if resolvedRecommendationID != recommendation.id {
      preparationGeneration += 1
      nextPreparationFailureStartsNewEpisode = nil
      clearFailedPreparation()
    }
    resolvedRecommendationID = recommendation.id
    currentRecommendation = recommendation
    if preparedChart?.recommendation.id != recommendation.id {
      preparedChart =
        resolvedAnalysis.primaryChart?.recommendation.id == recommendation.id
        ? resolvedAnalysis.primaryChart : nil
    }
    return .resolved(
      recommendation,
      analysis: resolvedAnalysis,
      defaultReason: defaultReason)
  }

  private func loadedAnalysis(for key: Request.Key) -> LoadedAnalysis? {
    guard let loadedAnalysis, loadedAnalysis.key == key else { return nil }
    return loadedAnalysis
  }

  private func ownedFailure(
    for requestKey: Request.Key,
    recommendationID: AutoChartRecommendationID?
  ) -> OwnedFailure? {
    if let failedAnalysis, failedAnalysis.key == requestKey {
      return .analysis(failedAnalysis)
    }
    guard loadedAnalysis(for: requestKey) != nil,
      let recommendationID,
      currentRecommendation?.id == recommendationID,
      let failedPreparation,
      failedPreparation.recommendationID == recommendationID
    else { return nil }
    return .preparation(failedPreparation)
  }

  /// Claims, commits, and records one failure without exposing a manually
  /// paired claim/record protocol to either failure path. The state commit runs
  /// before diagnostics so cancellation triggered by a test or sink cannot
  /// separate visible state from telemetry.
  private func commitFailureDiagnostic(
    _ failure: Failure,
    requestKey: Request.Key,
    recommendationID: AutoChartRecommendationID?,
    startsNewEpisode: Bool,
    commit: (ChartFailureDiagnosticStore.Claim) -> Void
  ) {
    let identity = ChartFailureDiagnosticStore.Identity(
      requestKey: requestKey,
      recommendationID: recommendationID,
      failure: failure)
    let claim = failureDiagnostics.claim(
      identity,
      startsNewEpisode: startsNewEpisode)
    commit(claim.claim)
    guard claim.shouldRecord else { return }
    let diagnostic: (code: String, summary: String) =
      switch (failure.stage, failure.kind) {
      case (.analysis, .invalidDataset):
        (
          "chart_analysis_invalid_dataset",
          "Chart analysis failed because the result data was invalid."
        )
      case (.analysis, .invalidSpecification):
        (
          "chart_analysis_invalid_specification",
          "Chart analysis produced an invalid chart specification."
        )
      case (.analysis, .transient):
        (
          "chart_analysis_failed",
          "Chart analysis failed and can be retried."
        )
      case (.preparation, .invalidDataset):
        (
          "chart_preparation_invalid_dataset",
          "Chart preparation failed because the result data was invalid."
        )
      case (.preparation, .invalidSpecification):
        (
          "chart_preparation_invalid_specification",
          "Chart preparation failed because the chart specification was invalid."
        )
      case (.preparation, .transient):
        (
          "chart_preparation_failed",
          "Chart preparation failed and can be retried."
        )
      }
    diagnostics.record(
      DiagnosticEvent(
        level: .error,
        category: .presentation,
        code: diagnostic.code,
        summary: diagnostic.summary,
        details: failure.details))
  }

  private func clearFailedAnalysis() {
    failedAnalysis = nil
  }

  private func clearFailedPreparation() {
    failedPreparation = nil
  }
}

extension CREGChartAnalysisClient: DependencyKey {
  static let liveValue = CREGChartAnalysisClient.live
  /// Computed so each access constructs a fresh uncached client; a shared
  /// `let` would let statistics accumulate across parallel tests.
  static var testValue: CREGChartAnalysisClient {
    CREGChartAnalysisClient(
      analyzer: AutoChartAnalyzer(configuration: .uncached),
      snapshots: .uncached)
  }
}

extension DependencyValues {
  var chartAnalysis: CREGChartAnalysisClient {
    get { self[CREGChartAnalysisClient.self] }
    set { self[CREGChartAnalysisClient.self] = newValue }
  }
}
