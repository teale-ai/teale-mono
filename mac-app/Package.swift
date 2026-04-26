// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "InferencePool",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "Teale", targets: ["Teale"]),
        .executable(name: "teale", targets: ["TealeCLI"]),
        .executable(name: "TealeCompanion", targets: ["TealeCompanion"]),
        .library(name: "TealeSDK", targets: ["TealeSDK", "TealeSDKUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.21.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", branch: "main"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "0.1.12"),
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0"),
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.0.0"),
        .package(url: "https://github.com/p2p-org/solana-swift", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
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

        // MARK: - LlamaCppKit (llama.cpp subprocess + HTTP provider)
        .target(
            name: "LlamaCppKit",
            dependencies: [
                "SharedTypes",
            ]
        ),

        // MARK: - TealeNetKit (Private TealeNet membership & certificates)
        .target(
            name: "TealeNetKit",
            dependencies: [
                "SharedTypes",
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
                "PrivacyFilterKit",
            ]
        ),

        // MARK: - CompilerKit (Mixture of Models — request compilation & fan-out)
        .target(
            name: "CompilerKit",
            dependencies: [
                "SharedTypes",
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

        // MARK: - ChatKit (P2P encrypted group chat — zero central storage)
        .target(
            name: "ChatKit",
            dependencies: [
                "SharedTypes",
                "CreditKit",
                "AgentKit",
            ]
        ),

        // MARK: - GatewayKit (gateway device identity + auth — macOS and iOS)
        .target(
            name: "GatewayKit",
            dependencies: [
                "SharedTypes",
            ]
        ),

        // MARK: - PrivacyFilterKit (desktop-local OPF orchestration)
        .target(
            name: "PrivacyFilterKit",
            dependencies: [
                "SharedTypes",
            ]
        ),

        // MARK: - LocalAPI
        .target(
            name: "LocalAPI",
            dependencies: [
                "SharedTypes",
                "InferenceEngine",
                "PrivacyFilterKit",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),

        // MARK: - AppCore (shared headless orchestration)
        .target(
            name: "AppCore",
            dependencies: [
                "SharedTypes",
                "HardwareProfile",
                "MLXInference",
                "LlamaCppKit",
                "TealeNetKit",
                "InferenceEngine",
                "ModelManager",
                "LocalAPI",
                "ClusterKit",
                "WANKit",
                "CreditKit",
                "WalletKit",
                "PrivacyFilterKit",
                "AgentKit",
                "AuthKit",
                "ChatKit",
                "CompilerKit",
                "GatewayKit",
            ]
        ),

        // MARK: - TealeCLI (headless CLI)
        .executableTarget(
            name: "TealeCLI",
            dependencies: [
                "AppCore",
                "SharedTypes",
                "LocalAPI",
                "AuthKit",
                "GatewayKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // MARK: - Teale (main macOS app executable)
        // Kept under Sources/InferencePoolApp/ for git history; target name drives
        // the output binary filename, which is what macOS shows in the dock.
        .executableTarget(
            name: "Teale",
            dependencies: [
                "AppCore",
                "SharedTypes",
                "HardwareProfile",
                "InferenceEngine",
                "ModelManager",
                "LlamaCppKit",
                "TealeNetKit",
                "LocalAPI",
                "ClusterKit",
                "WANKit",
                "CreditKit",
                "AgentKit",
                "AuthKit",
                "ChatKit",
                "GatewayKit",
            ],
            path: "Sources/InferencePoolApp",
            exclude: ["Info.plist", "InferencePool.entitlements"]
        ),

        // MARK: - TealeCompanion (iOS)
        .executableTarget(
            name: "TealeCompanion",
            dependencies: [
                "SharedTypes",
                "HardwareProfile",
                "MLXInference",
                "ModelManager",
                "InferenceEngine",
                "CreditKit",
                "AgentKit",
                "AuthKit",
                "WANKit",
                "ChatKit",
                "GatewayKit",
            ],
            exclude: ["Info.plist"],
            resources: [
                .process("Resources"),
            ]
        ),

        // MARK: - TealeSDK (third-party resource contribution SDK)
        .target(
            name: "TealeSDK",
            dependencies: [
                "SharedTypes",
                "HardwareProfile",
                "InferenceEngine",
                "MLXInference",
                "WANKit",
                "CreditKit",
                "ClusterKit",
            ]
        ),

        // MARK: - TealeSDKUI (pre-built SwiftUI views for TealeSDK)
        .target(
            name: "TealeSDKUI",
            dependencies: [
                "TealeSDK",
                "SharedTypes",
                "CreditKit",
                "HardwareProfile",
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
            name: "PrivacyFilterKitTests",
            dependencies: ["PrivacyFilterKit"]
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
        .testTarget(
            name: "ChatKitTests",
            dependencies: ["ChatKit"]
        ),
        .testTarget(
            name: "TealeSDKTests",
            dependencies: ["TealeSDK"]
        ),
        .testTarget(
            name: "TealeTests",
            dependencies: ["Teale", "AppCore", "GatewayKit", "WANKit"]
        ),
    ]
)
