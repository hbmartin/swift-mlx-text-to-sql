// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CREGKit",
  platforms: [.iOS("26.0"), .macOS("15.0")],
  products: [
    // Inference + pipeline engine, no UI and no TCA — shared by the app and
    // the creg-eval-cli parity harness (docs/adr/0003-hybrid-eval-harness.md).
    .library(name: "CREGEngine", targets: ["CREGEngine"]),
    // TCA features + SwiftUI chat surface consumed by the app shell.
    .library(name: "CREGFeatures", targets: ["CREGFeatures"]),
  ],
  dependencies: [
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
    // Concrete Hub and tokenizer adapters avoid compiler-plugin loading in
    // application builds while preserving the pinned MLXLM loading contract.
    .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0"),
  ],
  targets: [
    .target(
      name: "CREGEngine",
      dependencies: [
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "MLXStructured", package: "mlx-swift-structured"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      resources: [
        .copy("Resources/sql_grammar.ebnf"),
        .copy("Resources/schema_prompt.txt"),
        .copy("Resources/canonical_result_fixtures.json"),
      ]
    ),
    .target(
      name: "CREGFeatures",
      dependencies: [
        "CREGEngine",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .executableTarget(
      name: "creg-eval-cli",
      dependencies: ["CREGEngine"]
    ),
    .testTarget(
      name: "CREGKitTests",
      dependencies: ["CREGEngine", "CREGFeatures"]
    ),
  ]
)
