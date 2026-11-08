import Foundation

/// User preferences for choosing an AI backend. API credentials deliberately live
/// in KeychainStore and are never part of this Codable value.
public struct AISettings: Codable, Equatable, Sendable {
    public var backend: AIBackend
    public var cliModel: String
    public var messagesAPIModel: String
    public var claudeCLIPath: String?
    public var codexCLIPath: String?
    public var codexModel: String
    public var messagesAPIVersion: String
    public var maxOutputTokens: Int

    public init(backend: AIBackend = .claudeCLI,
                cliModel: String = Self.defaultCLIModel,
                messagesAPIModel: String = Self.defaultMessagesAPIModel,
                claudeCLIPath: String? = nil,
                codexCLIPath: String? = nil,
                codexModel: String = Self.defaultCodexModel,
                messagesAPIVersion: String = Self.defaultAPIVersion,
                maxOutputTokens: Int = 32_768) {
        self.backend = backend
        self.cliModel = cliModel
        self.messagesAPIModel = messagesAPIModel
        self.claudeCLIPath = claudeCLIPath
        self.codexCLIPath = codexCLIPath
        self.codexModel = codexModel
        self.messagesAPIVersion = messagesAPIVersion
        self.maxOutputTokens = min(max(maxOutputTokens, 256), 128_000)
    }

    public static let `default` = AISettings()
    public static let defaultCLIModel = "opus"
    public static let learningPointCLIModel = "sonnet"
    public static let learningPointAPIModel = "claude-sonnet-5-5"
    public static let defaultCodexModel = "gpt-6.1-sol"
    public static let defaultMessagesAPIModel = "claude-opus-5-5"
    public static let defaultAPIVersion = "2026-10-21"

    public var selectedModel: String {
        switch backend {
        case .claudeCLI: cliModel
        case .messagesAPI: messagesAPIModel
        case .codexCLI: codexModel
        }
    }

    private enum CodingKeys: String, CodingKey {
        case backend, cliModel, messagesAPIModel, claudeCLIPath, codexCLIPath, codexModel, messagesAPIVersion, maxOutputTokens
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            backend: try values.decodeIfPresent(AIBackend.self, forKey: .backend) ?? Self.default.backend,
            cliModel: try values.decodeIfPresent(String.self, forKey: .cliModel) ?? Self.defaultCLIModel,
            messagesAPIModel: try values.decodeIfPresent(String.self, forKey: .messagesAPIModel) ?? Self.defaultMessagesAPIModel,
            claudeCLIPath: try values.decodeIfPresent(String.self, forKey: .claudeCLIPath),
            codexCLIPath: try values.decodeIfPresent(String.self, forKey: .codexCLIPath),
            codexModel: try values.decodeIfPresent(String.self, forKey: .codexModel) ?? Self.defaultCodexModel,
            messagesAPIVersion: try values.decodeIfPresent(String.self, forKey: .messagesAPIVersion) ?? Self.defaultAPIVersion,
            maxOutputTokens: try values.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? 32_768
        )
    }
}

/// Small settings store backed by UserDefaults. It never accepts or persists API keys.
public actor AISettingsStore {
    private let defaults: UserDefaults
    private let storageKey: String

    public init(defaults: UserDefaults = .standard, storageKey: String = "lectern.ai.settings") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func load() -> AISettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(AISettings.self, from: data) else {
            return .default
        }
        return settings
    }

    public func save(_ settings: AISettings) throws {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: storageKey)
        } catch {
            throw AIError.configuration("AI settings could not be saved: \(error.localizedDescription)")
        }
    }

    public func reset() {
        defaults.removeObject(forKey: storageKey)
    }
}
