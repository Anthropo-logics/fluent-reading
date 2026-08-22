// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "lectura-translate-runtime",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.3"),
    .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.0.0"),
  ],
  targets: [
    .executableTarget(
      name: "lectura-translate-runtime",
      dependencies: [
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "Hub", package: "swift-transformers"),
        .product(name: "Tokenizers", package: "swift-transformers"),
      ]
    )
  ]
)
