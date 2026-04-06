import Foundation
import MLXLMCommon
import Hub
import Tokenizers

// MARK: - Shared HubApi with App Support cache (avoids ~/Documents TCC prompt)

/// Custom HubApi that stores models in ~/Library/Application Support/Teale/huggingface/
/// instead of ~/Documents/huggingface/ to avoid macOS TCC permission prompts on every launch.
public let tealeHubApi: HubApi = {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let cacheDir = appSupport.appendingPathComponent("Teale/huggingface", isDirectory: true)
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    return HubApi(downloadBase: cacheDir)
}()

// MARK: - HuggingFace Hub Downloader

/// Implements the MLXLMCommon.Downloader protocol using swift-transformers' Hub module
public struct HFDownloader: MLXLMCommon.Downloader, Sendable {
    private let hubApi: HubApi

    public init(hubApi: HubApi = tealeHubApi) {
        self.hubApi = hubApi
    }

    public func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let repo = Hub.Repo(id: id)
        let snapshotURL = try await hubApi.snapshot(
            from: repo,
            matching: patterns,
            progressHandler: progressHandler
        )
        return snapshotURL
    }
}

// MARK: - Tokenizer Loader

/// Implements the MLXLMCommon.TokenizerLoader protocol using swift-transformers
public struct HFTokenizerLoader: MLXLMCommon.TokenizerLoader, Sendable {
    public init() {}

    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory, hubApi: tealeHubApi)
        return TokenizerAdapter(tokenizer)
    }
}

// MARK: - Tokenizer Adapter

/// Bridges swift-transformers' Tokenizer to MLXLMCommon.Tokenizer
struct TokenizerAdapter: MLXLMCommon.Tokenizer {
    private let inner: any Tokenizers.Tokenizer

    init(_ tokenizer: any Tokenizers.Tokenizer) {
        self.inner = tokenizer
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        inner.encode(text: text)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        inner.decode(tokens: tokenIds)
    }

    func convertTokenToId(_ token: String) -> Int? {
        inner.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        inner.convertIdToToken(id)
    }

    var bosToken: String? {
        inner.bosToken
    }

    var eosToken: String? {
        inner.eosToken
    }

    var unknownToken: String? {
        inner.unknownToken
    }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        // Convert Sendable messages to String-valued for swift-transformers
        let stringMessages = messages.map { msg -> [String: String] in
            msg.compactMapValues { $0 as? String }
        }
        return try inner.applyChatTemplate(messages: stringMessages)
    }
}
