struct DiagnosticsClient {
  static let noop = DiagnosticsClient()
  static let silentSink = DiagnosticsClient()
}

final class ResultChartLoader {
  // ruleid: creg-chart-loaders-require-explicit-diagnostics
  init(client: Int, diagnostics: DiagnosticsClient = .noop, warmStart: Bool) {}
}

final class ResultChartLoaderOwner {
  // ruleid: creg-chart-loaders-require-explicit-diagnostics
  init(client: Int, diagnostics: DiagnosticsClient = .silentSink) {}
}

final class ExplicitResultChartLoader {
  // ok: creg-chart-loaders-require-explicit-diagnostics
  init(client: Int, diagnostics: DiagnosticsClient, warmStart: Bool) {}
}

final class UnrelatedLoader {
  // ok: creg-chart-loaders-require-explicit-diagnostics
  init(diagnostics: DiagnosticsClient = .noop) {}
}
