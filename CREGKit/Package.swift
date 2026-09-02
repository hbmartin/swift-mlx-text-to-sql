// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CREGKit",
  platforms: [.iOS("26.0"), .macOS("15.0")],
  products: [
    .library(name: "CREGCore", targets: ["CREGCore"]),
    .library(name: "CREGData", targets: ["CREGData"]),
    .library(name: "CREGInference", targets: ["CREGInference"]),
    .library(name: "CREGEngine", targets: ["CREGEngine"]),
    .library(name: "CREGFeatures", targets: ["CREGFeatures"]),
    .library(name: "CREGApplication", targets: ["CREGApplication"]),
  ],
  dependencies: [
    // Recommendation behavior is part of CREG's persisted presentation
    // contract. This pin must carry policy v11: CREG preserves the user's
    // table/chart mode while clearing older chart-type pins. Integration tests
    // pin that policy, the affected box-plot fixtures, and CREG's selection
    // formatting and accessibility contract with the package renderer.
    .package(
      url: "https://github.com/hbmartin/AutoTableCharts.git",
      revision: "abd5058b98a22a5c2a231e02b468afe0e5952df4"),
    // 0.31.5+ requires Swift tools 6.3. Keep the MLX runtime compatible with
    // the project's Xcode 26.3 / Swift 6.2.4 toolchain.
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
    .package(
      url: "https://github.com/ml-explore/mlx-swift-lm",
      exact: "3.31.4"),
    // The 0.2.0 tag raises MLX Swift to 0.31.5 (Swift tools 6.3). This is the
    // last upstream structured-decoding revision compatible with MLX 0.31.4
    // while retaining the 3.x MLXLM API used by CREG.
    .package(
      url: "https://github.com/petrukha-ivan/mlx-swift-structured",
      revision: "747fe3117311e3de1e43fcbc5f8cb164227bd1f3"),
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.0"),
    // Interoperable ZIP creation for the Support Bundle export.
    .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.20"),
    // Concrete Hub and tokenizer adapters avoid compiler-plugin loading in
    // application builds while preserving the pinned MLXLM loading contract.
    .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0"),
  ],
  targets: [
    .target(name: "CREGCore"),
    .target(
      name: "CREGData",
      dependencies: [
        "CREGCore",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      resources: [
        .copy("Resources/schema_catalog.json"),
      ]
    ),
    .target(
      name: "CREGInference",
      dependencies: [
        "CREGCore",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "MLXStructured", package: "mlx-swift-structured"),
      ],
      resources: [
        .copy("Resources/sql_grammar.ebnf"),
        .copy("Resources/schema_prompt.txt"),
        .copy("Resources/system_prompt_template.txt"),
        .copy("Resources/repair_prompt_template.txt"),
        .copy("Resources/sql_draft_corpus.json"),
      ]
    ),
    .target(
      name: "CREGEngine",
      dependencies: [
        "CREGCore",
        "CREGData",
      ]
    ),
    .target(
      name: "CREGFeatures",
      dependencies: [
        "CREGCore",
        "CREGEngine",
        .product(name: "AutoTableCharts", package: "AutoTableCharts"),
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      resources: [
        // Byte-exact copy of eval/gold/answerability.jsonl for the debug
        // on-device capture; a CREGFeaturesTests test pins the equality.
        .copy("Resources/answerability.jsonl")
      ]
    ),
    .target(
      name: "CREGApplication",
      dependencies: [
        "CREGCore",
        "CREGData",
        "CREGInference",
        "CREGEngine",
        "CREGFeatures",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .executableTarget(
      name: "creg-eval-cli",
      dependencies: ["CREGCore", "CREGData", "CREGInference", "CREGEngine"]
    ),
    // Offline answerability scoring (docs/eval.md "Answerability"): corpus +
    // captured FM verdicts in, deterministic confusion matrix out. No FM, no
    // database, no MLX — it runs identically on macOS 15 and in CI.
    .executableTarget(
      name: "creg-answerability-cli",
      dependencies: ["CREGCore"]
    ),
    // Test-only helpers shared across test targets. Not exposed as a product,
    // so it stays out of the dependency graph of anything that consumes CREGKit.
    .target(
      name: "CREGTestSupport",
      dependencies: ["CREGCore", "CREGData"],
      path: "Tests/CREGTestSupport"
    ),
    .testTarget(
      name: "CREGCoreTests",
      dependencies: ["CREGCore"],
      resources: [.copy("Resources/canonical_result_fixtures.json")]
    ),
    .testTarget(
      name: "CREGDataTests",
      dependencies: [
        "CREGCore",
        "CREGData",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      resources: [.copy("Resources/sqlite_text_fixtures.json")]
    ),
    .testTarget(
      name: "CREGInferenceTests",
      dependencies: [
        "CREGCore",
        "CREGData",
        "CREGInference",
        "CREGTestSupport",
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      resources: [.copy("Resources/sql_cutter_fixtures.json")]
    ),
    .testTarget(
      name: "CREGEngineTests",
      dependencies: ["CREGCore", "CREGData", "CREGEngine", "CREGTestSupport"]
    ),
    .testTarget(
      name: "CREGFeaturesTests",
      dependencies: [
        "CREGCore",
        "CREGData",
        "CREGInference",
        "CREGEngine",
        "CREGFeatures",
        "CREGTestSupport",
        .product(name: "AutoTableCharts", package: "AutoTableCharts"),
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "ZIPFoundation", package: "ZIPFoundation"),
      ]
    ),
  ]
)
