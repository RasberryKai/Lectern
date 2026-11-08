import Foundation
import LecternCore

/// Thread-safe holder for the provider configuration the user chose in Settings.
nonisolated final class ProviderConfiguration: @unchecked Sendable {
    private let lock = NSLock()
    private var settings: AISettings
    init(_ settings: AISettings) { self.settings = settings }
    var current: AISettings { lock.withLock { settings } }
    func update(_ settings: AISettings) { lock.withLock { self.settings = settings } }
}

/// The JobRunner owns global concurrency and must live as long as the library, so it is
/// created once. Instead of recreating it when Settings change, each call builds the real
/// provider from the configuration current at that moment. A running call keeps the provider
/// it started with; new calls pick up a changed CLI path, API version or output limit.
nonisolated struct ConfigurableProvider: AIProvider {
    let backend: AIBackend
    let configuration: ProviderConfiguration
    let keychain: KeychainStore

    func execute(_ request: AIRequest, onEvent: @escaping @Sendable (AIEvent) -> Void) async throws -> AIResponse {
        let settings = configuration.current
        switch backend {
        case .claudeCLI:
            return try await ClaudeCLIProvider(settings: settings).execute(request, onEvent: onEvent)
        case .codexCLI:
            return try await CodexCLIProvider(settings: settings).execute(request, onEvent: onEvent)
        case .messagesAPI:
            return try await MessagesAPIProvider(settings: settings, keychain: keychain).execute(request, onEvent: onEvent)
        }
    }
}

extension AIBackend {
    var displayName: String {
        switch self {
        case .claudeCLI: "Claude CLI"
        case .codexCLI: "Codex CLI"
        case .messagesAPI: "Anthropic API"
        }
    }
    var billingNote: String {
        switch self {
        case .claudeCLI: "your subscription"
        case .codexCLI: "your ChatGPT account"
        case .messagesAPI: "billed per token"
        }
    }

    var assistantName: String {
        switch self {
        case .claudeCLI: "Claude"
        case .codexCLI: "Codex"
        case .messagesAPI: "AI"
        }
    }

    var iconName: String {
        switch self {
        case .claudeCLI, .codexCLI: "terminal"
        case .messagesAPI: "key"
        }
    }

    var foundStatus: String {
        switch self {
        case .claudeCLI: "Claude CLI found"
        case .codexCLI: "Codex CLI found"
        case .messagesAPI: "Anthropic API key saved"
        }
    }

    var missingStatus: String {
        switch self {
        case .claudeCLI: "Claude CLI not found"
        case .codexCLI: "Codex CLI not found"
        case .messagesAPI: "API key missing"
        }
    }
}
