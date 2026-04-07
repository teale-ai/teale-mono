// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "InferencePool",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "InferencePoolApp", targets: ["InferencePoolApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.21.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "0.1.12"),
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0"),
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.0.0"),
        .package(url: "https://github.com/p2p-org/solana-swift", from: "5.0.0"),
    ],
    targets: [
        // MARK: - SharedTypes
        .target(
            name: "SharedTypes",
            dependencies: []
        ),

        // MARK: - HardwareProfile
        .target(
            name: "HardwareProfile",
            dependencies: ["SharedTypes"]
        ),

        // MARK: - MLXInference
        .target(
            name: "MLXInference",
            dependencies: [
                "SharedTypes",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Transformers", package: "swift-transformers"),
            ]
        ),

        // MARK: - ModelManager
        .target(
            name: "ModelManager",
            dependencies: [
                "SharedTypes",
                "HardwareProfile",
                "MLXInference",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
            ]
        ),

        // MARK: - InferenceEngine (provider-agnostic — no MLX dependency)
        .target(
            name: "InferenceEngine",
            dependencies: [
                "SharedTypes",
                "HardwareProfile",
            ]
        ),

        // MARK: - ClusterKit (LAN cluster networking)
        .target(
            name: "ClusterKit",
            dependencies: [
                "SharedTypes",
                "HardwareProfile",
            ]
        ),

        // MARK: - WANKit (WAN P2P networking)
        .target(
            name: "WANKit",
            dependencies: [
                "SharedTypes",
                "HardwareProfile",
                "ClusterKit",
            ]
        ),

        // MARK: - CreditKit
        .target(
            name: "CreditKit",
            dependencies: [
                "SharedTypes",
            ]
        ),

        // MARK: - AuthKit
        .target(
            name: "AuthKit",
            dependencies: [
                "SharedTypes",
                .product(name: "Supabase", package: "supabase-swift"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),

        // MARK: - WalletKit (Solana USDC integration)
        .target(
            name: "WalletKit",
            dependencies: [
                "SharedTypes",
                "CreditKit",
                .product(name: "SolanaSwift", package: "solana-swift"),
            ]
        ),

        // MARK: - AgentKit (agent-to-agent communication)
        .target(
            name: "AgentKit",
            dependencies: [
                "SharedTypes",
                "CreditKit",
            ]
        ),

        // MARK: - LocalAPI
        .target(
            name: "LocalAPI",
            dependencies: [
                "SharedTypes",
                "InferenceEngine",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),

        // MARK: - InferencePoolApp (main executable)
        .executableTarget(
            name: "InferencePoolApp",
            dependencies: [
                "SharedTypes",
                "HardwareProfile",
                "MLXInference",
                "InferenceEngine",
                "ModelManager",
                "LocalAPI",
                "ClusterKit",
                "WANKit",
                "CreditKit",
                "WalletKit",
                "AgentKit",
                "AuthKit",
            ],
            exclude: ["Info.plist", "InferencePool.entitlements"]
        ),

        // MARK: - SolairCompanion (iOS)
        .executableTarget(
            name: "SolairCompanion",
            dependencies: [
                "SharedTypes",
                "AgentKit",
                "AuthKit",
            ]
        ),

        // MARK: - Tests
        .testTarget(
            name: "SharedTypesTests",
            dependencies: ["SharedTypes"]
        ),
        .testTarget(
            name: "HardwareProfileTests",
            dependencies: ["HardwareProfile"]
        ),
        .testTarget(
            name: "ModelManagerTests",
            dependencies: ["ModelManager"]
        ),
        .testTarget(
            name: "InferenceEngineTests",
            dependencies: ["InferenceEngine"]
        ),
        .testTarget(
            name: "WANKitTests",
            dependencies: ["WANKit"]
        ),
        .testTarget(
            name: "CreditKitTests",
            dependencies: ["CreditKit"]
        ),
        .testTarget(
            name: "WalletKitTests",
            dependencies: ["WalletKit"]
        ),
        .testTarget(
            name: "AgentKitTests",
            dependencies: ["AgentKit"]
        ),
    ]
)
