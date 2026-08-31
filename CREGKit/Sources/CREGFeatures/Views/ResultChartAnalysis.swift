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

  func removeAll() async {
    snapshots.removeAll()
    await analyzer.removeAll()
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
  fileprivate var analysisGeneration: Int
  fileprivate var recommendationID: AutoChartRecommendationID?
  fileprivate var attempt: Int
}

/// Defers loader construction until SwiftUI reads the state owner retained for
/// this view identity. Recomputed view values create only this inexpensive
/// wrapper; discarded values never probe or resolve the warm-start snapshot.
@MainActor
final class ResultChartLoaderOwner {
  typealias MakeLoader =
    @MainActor (
      ResultChartLoader.Request,
      AutoChartRecommendationID?
    ) -> ResultChartLoader

  private var makeLoader: MakeLoader?
  private var storedLoader: ResultChartLoader?

  init(client: CREGChartAnalysisClient) {
    self.makeLoader = { request, preferredSpecificationID in
      ResultChartLoader(
        client: client,
        warmStart: request,
        preferredSpecificationID: preferredSpecificationID)
    }
  }

  init(makeLoader: @escaping MakeLoader) {
    self.makeLoader = makeLoader
  }

  /// The first retained view value supplies the authoritative request. This
  /// avoids freezing a request from an earlier, unrendered value in `@State`.
  /// Releasing the one-shot factory also releases everything it captured.
  func loader(
    warmStart request: ResultChartLoader.Request,
    preferredSpecificationID: AutoChartRecommendationID?
  ) -> ResultChartLoader {
    if let storedLoader { return storedLoader }
    guard let makeLoader else {
      preconditionFailure("A chart loader owner lost its construction factory.")
    }
    let loader = makeLoader(request, preferredSpecificationID)
    storedLoader = loader
    self.makeLoader = nil
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

  enum Resolution {
    case resolved(
      AutoChartRecommendation,
      analysis: AutoChartAnalysis<Int>,
      defaultReason: AutoChartRecommendationResolution.DefaultReason?)
    case unavailable
    case failed(details: String)
  }

  private struct LoadedAnalysis {
    let key: Request.Key
    let value: AutoChartAnalysis<Int>
  }

  private var loadedAnalysis: LoadedAnalysis?
  private var failedAnalysisKey: Request.Key?
  private var activeRequestKey: Request.Key?
  private var currentRecommendation: AutoChartRecommendation?
  private var preparedChart: AutoChartPreparedChart<Int>?
  private var failedPreparationRecommendationID: AutoChartRecommendationID?
  private let analyzeChart: AnalyzeChart
  private let prepareChart: PrepareChart
  /// The recommendation the loader most recently resolved or was asked to
  /// prepare. A resolution change supersedes preparation still suspended for
  /// the previous recommendation, even when the analysis itself is reused.
  private var resolvedRecommendationID: AutoChartRecommendationID?
  /// Every call supersedes earlier preparation calls, including calls for a
  /// different recommendation in the same analysis generation.
  private var preparationGeneration = 0
  /// Explicit retries re-key SwiftUI's preparation task even when the analysis
  /// and recommendation are unchanged.
  private var preparationAttempt = 0
  /// Explicit retries re-key SwiftUI's analysis task without changing the
  /// request or pin that determine the analysis result.
  private var analysisAttempt = 0
  /// Identity of the analysis this loader currently owns. It prevents both a
  /// superseded analysis and a preparation suspended on its predecessor from
  /// committing after a newer request has taken ownership of the loader.
  private var analysisGeneration = 0

  init(
    client: CREGChartAnalysisClient,
    warmStart request: Request?,
    preferredSpecificationID: AutoChartRecommendationID? = nil,
    analyzeChart: AnalyzeChart? = nil,
    prepareChart: PrepareChart? = nil
  ) {
    activeRequestKey = request?.key
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
    if let loadedAnalysis, loadedAnalysis.key == request.key {
      failedAnalysisKey = nil
      return applyResolution(
        of: loadedAnalysis.value,
        preferred: preferredSpecificationID)
    }

    failedAnalysisKey = nil
    failedPreparationRecommendationID = nil
    resolvedRecommendationID = nil
    currentRecommendation = nil
    loadedAnalysis = nil
    preparedChart = nil
    analysisGeneration += 1
    let requestGeneration = analysisGeneration
    do {
      let loaded = try await analyzeChart(request)
      try Task.checkCancellation()
      guard requestGeneration == analysisGeneration else { return nil }
      loadedAnalysis = LoadedAnalysis(key: request.key, value: loaded)
      return applyResolution(
        of: loaded,
        preferred: preferredSpecificationID)
    } catch {
      guard !Task.isCancelled, requestGeneration == analysisGeneration else {
        return nil
      }
      failedAnalysisKey = request.key
      return .failed(details: DiagnosticDetails.describe(error))
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

  /// Whether the current request owns an analyzer failure that can be retried.
  /// `false` also covers pending, successful, unavailable, and superseded work.
  func analysisRetryAvailable(for key: Request.Key) -> Bool {
    failedAnalysisKey == key
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
  /// during that interval.
  func matchingPreparedChart(
    for recommendationID: AutoChartRecommendationID
  ) -> AutoChartPreparedChart<Int>? {
    guard preparedChart?.recommendation.id == recommendationID else {
      return nil
    }
    return preparedChart
  }

  func preparationFailed(
    for recommendationID: AutoChartRecommendationID?
  ) -> Bool {
    guard let recommendationID else { return false }
    return failedPreparationRecommendationID == recommendationID
  }

  /// Prepares the selected recommendation's chart, reusing the analysis's
  /// primary chart when it matches. Only the latest invocation may commit;
  /// cancellation is cooperative and therefore cannot be the commit guard.
  func prepareResolvedRecommendation(for requestKey: Request.Key) async {
    preparationGeneration += 1
    let preparation = preparationGeneration
    failedPreparationRecommendationID = nil
    guard let chartAnalysis = loadedAnalysis(for: requestKey)?.value,
      let recommendation = currentRecommendation
    else {
      preparedChart = nil
      return
    }
    if chartAnalysis.primaryChart?.recommendation.id == recommendation.id {
      preparedChart = chartAnalysis.primaryChart
      return
    }
    preparedChart = nil
    let requestAnalysisGeneration = analysisGeneration
    do {
      let prepared = try await prepareChart(chartAnalysis, recommendation.id)
      guard requestAnalysisGeneration == analysisGeneration,
        preparation == preparationGeneration,
        resolvedRecommendationID == recommendation.id
      else { return }
      preparedChart = prepared
    } catch {
      guard !Task.isCancelled,
        requestAnalysisGeneration == analysisGeneration,
        preparation == preparationGeneration,
        resolvedRecommendationID == recommendation.id
      else { return }
      failedPreparationRecommendationID = recommendation.id
    }
  }

  /// Identity used by both chart surfaces for their preparation task. Keeping
  /// the loader's generations private prevents either view from reimplementing
  /// only part of the selection and replacement-analysis contract.
  func preparationTaskKey(
    recommendationID: AutoChartRecommendationID?
  ) -> ResultChartPreparationTaskKey {
    ResultChartPreparationTaskKey(
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
    activeRequestKey = requestKey
    failedAnalysisKey = nil
    failedPreparationRecommendationID = nil
    resolvedRecommendationID = nil
    currentRecommendation = nil
    loadedAnalysis = nil
    preparedChart = nil
    analysisGeneration += 1
    preparationGeneration += 1
  }

  /// Clears the current retryable analysis failure and advances the SwiftUI
  /// task identity.
  /// A stale surface cannot retry a failure belonging to a replacement request.
  func retryAnalysis(for requestKey: Request.Key) {
    guard failedAnalysisKey == requestKey else { return }
    failedAnalysisKey = nil
    analysisAttempt += 1
  }

  /// Clears the visible failure, invalidates suspended preparation, and
  /// advances the task identity so SwiftUI starts a fresh attempt.
  func retryPreparation() {
    failedPreparationRecommendationID = nil
    preparationGeneration += 1
    preparationAttempt += 1
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
      failedPreparationRecommendationID = nil
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
      failedPreparationRecommendationID = nil
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
