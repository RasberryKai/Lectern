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
        case .messagesAPI:
            return try await MessagesAPIProvider(settings: settings, keychain: keychain).execute(request, onEvent: onEvent)
        }
    }
}

extension AIBackend {
    var displayName: String {
        switch self {
        case .claudeCLI: "Claude CLI"
        case .messagesAPI: "Anthropic API"
        }
    }
    var billingNote: String {
        switch self {
        case .claudeCLI: "your subscription"
        case .messagesAPI: "billed per token"
        }
    }
}
