struct DiagnosticsClient {
  static let noop = DiagnosticsClient()
  static let silentSink = DiagnosticsClient()
}

final class ResultChartLoader {
  // ruleid: creg-chart-loaders-require-explicit-diagnostics
  init(client: Int, diagnostics: DiagnosticsClient = .noop, warmStart: Bool) {}

  // ok: creg-chart-loaders-require-explicit-diagnostics
  init(client: String, diagnostics: DiagnosticsClient, warmStart: Bool) {}
}

final class ResultChartLoaderOwner {
  // ruleid: creg-chart-loaders-require-explicit-diagnostics
  init(client: Int, diagnostics: DiagnosticsClient = .silentSink) {}

  // ok: creg-chart-loaders-require-explicit-diagnostics
  init(client: String, diagnostics: DiagnosticsClient) {}
}

final class UnrelatedLoader {
  // ok: creg-chart-loaders-require-explicit-diagnostics
  init(diagnostics: DiagnosticsClient = .noop) {}
}
