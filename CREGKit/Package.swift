// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CREGKit",
  platforms: [.iOS("26.0"), .macOS("26.0")],
  products: [
    // Inference + pipeline engine, no UI and no TCA — shared by the app and
    // the creg-eval-cli parity harness (docs/adr/0003-hybrid-eval-harness.md).
    .library(name: "CREGEngine", targets: ["CREGEngine"]),
    // TCA features + SwiftUI chat surface consumed by the app shell.
    .library(name: "CREGFeatures", targets: ["CREGFeatures"]),
  ],
  dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.4"),
    .package(url: "https://github.com/petrukha-ivan/mlx-swift-structured", from: "0.2.0"),
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.0"),
    // Needed directly because the MLXHuggingFace loading macros expand
    // HubClient/Tokenizers references into this module's code.
    .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
  ],
  targets: [
    .target(
      name: "CREGEngine",
      dependencies: [
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
        .product(name: "HuggingFace", package: "swift-huggingface"),
        .product(name: "Tokenizers", package: "swift-transformers"),
        .product(name: "MLXStructured", package: "mlx-swift-structured"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ],
      resources: [
        .copy("Resources/sql_grammar.ebnf"),
        .copy("Resources/schema_prompt.txt"),
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
