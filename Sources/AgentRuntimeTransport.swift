import Foundation

enum AgentDeliveryMode: String, CaseIterable, Codable, Identifiable {
    case pasteOnly
    case pasteAndSend
    case sendOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pasteOnly:
            return "Paste Only"
        case .pasteAndSend:
            return "Paste + Send"
        case .sendOnly:
            return "Send Only"
        }
    }

    var requiresAccessibilityPermission: Bool {
        switch self {
        case .sendOnly:
            return false
        case .pasteOnly, .pasteAndSend:
            return true
        }
    }

    var includesAgentDelivery: Bool {
        switch self {
        case .pasteOnly:
            return false
        case .pasteAndSend, .sendOnly:
            return true
        }
    }

    var includesPaste: Bool {
        switch self {
        case .pasteOnly, .pasteAndSend:
            return true
        case .sendOnly:
            return false
        }
    }
}

enum AgentProviderKind: String, CaseIterable, Codable, Identifiable {
    case automatic
    case groq
    case litellm
    case ollama
    case openAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .groq:
            return "Groq"
        case .litellm:
            return "LiteLLM"
        case .ollama:
            return "Ollama"
        case .openAICompatible:
            return "OpenAI-Compatible"
        }
    }

    var providerName: String {
        switch self {
        case .automatic:
            return "automatic"
        case .groq:
            return "groq"
        case .litellm:
            return "litellm"
        case .ollama:
            return "ollama"
        case .openAICompatible:
            return "openai-compatible"
        }
    }
}

struct AgentTransportConfiguration {
    let deliveryMode: AgentDeliveryMode
    let providerKind: AgentProviderKind
    let webSocketURL: String
    let webhookURL: String
    let apiBaseURL: String

    var trimmedWebSocketURL: String {
        webSocketURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedWebhookURL: String {
        webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var webSocketEndpoint: URL? {
        guard let url = URL(string: trimmedWebSocketURL), !trimmedWebSocketURL.isEmpty else {
            return nil
        }
        return url
    }

    var webhookEndpoint: URL? {
        guard let url = URL(string: trimmedWebhookURL), !trimmedWebhookURL.isEmpty else {
            return nil
        }
        return url
    }

    var hasDestination: Bool {
        webSocketEndpoint != nil || webhookEndpoint != nil
    }
}

enum AgentRuntimeTransportError: LocalizedError {
    case noDestinationConfigured
    case invalidHTTPResponse
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .noDestinationConfigured:
            return "Agent delivery is enabled but no websocket or HTTP fallback endpoint is configured."
        case .invalidHTTPResponse:
            return "Agent delivery returned a non-HTTP response."
        case .requestFailed(let statusCode, let details):
            return "Agent delivery failed with status \(statusCode): \(details)"
        }
    }
}

struct AgentRuntimeEvent: Codable {
    struct ProviderMetadata: Codable {
        let apiBaseURL: String
        let provider: String
        let isLiteLLM: Bool
    }

    struct AppMetadata: Codable {
        let appName: String?
        let bundleIdentifier: String?
        let windowTitle: String?
        let selectedText: String?
        let contextSummary: String?
    }

    struct TranscriptPayload: Codable {
        let raw: String?
        let processed: String?
    }

    let version = 1
    let source = "freeflow"
    let eventID: UUID
    let sessionID: UUID
    let type: String
    let timestamp: String
    let deliveryMode: String
    let intent: String
    let status: String?
    let error: String?
    let provider: ProviderMetadata
    let app: AppMetadata
    let transcript: TranscriptPayload
}

actor AgentRuntimeTransport {
    private static let agentRequestTimeout: TimeInterval = 10
    private static let agentResourceTimeout: TimeInterval = 15

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = Self.agentRequestTimeout
        configuration.timeoutIntervalForResource = Self.agentResourceTimeout
        return URLSession(configuration: configuration)
    }()

    private var webSocketTask: URLSessionWebSocketTask?
    private var connectedWebSocketURL: URL?

    func send(
        _ event: AgentRuntimeEvent,
        configuration: AgentTransportConfiguration
    ) async throws {
        guard configuration.deliveryMode.includesAgentDelivery else { return }
        guard configuration.hasDestination else {
            throw AgentRuntimeTransportError.noDestinationConfigured
        }

        if let webSocketEndpoint = configuration.webSocketEndpoint {
            do {
                try await sendViaWebSocket(event, to: webSocketEndpoint, retryOnFailure: true)
                return
            } catch {
                resetWebSocket()
                if let webhookEndpoint = configuration.webhookEndpoint {
                    try await sendViaHTTP(event, to: webhookEndpoint)
                    return
                }
                throw error
            }
        }

        if let webhookEndpoint = configuration.webhookEndpoint {
            try await sendViaHTTP(event, to: webhookEndpoint)
        }
    }

    private func sendViaWebSocket(
        _ event: AgentRuntimeEvent,
        to endpoint: URL,
        retryOnFailure: Bool
    ) async throws {
        let task = ensureWebSocketTask(for: endpoint)
        let data = try JSONEncoder().encode(event)
        let text = String(decoding: data, as: UTF8.self)

        do {
            try await task.send(.string(text))
        } catch {
            resetWebSocket()
            guard retryOnFailure else { throw error }
            try await sendViaWebSocket(event, to: endpoint, retryOnFailure: false)
        }
    }

    private func ensureWebSocketTask(for endpoint: URL) -> URLSessionWebSocketTask {
        if connectedWebSocketURL != endpoint {
            resetWebSocket()
        }

        if let webSocketTask {
            return webSocketTask
        }

        let task = session.webSocketTask(with: endpoint)
        task.resume()
        webSocketTask = task
        connectedWebSocketURL = endpoint
        return task
    }

    private func sendViaHTTP(_ event: AgentRuntimeEvent, to endpoint: URL) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(event)

        let (data, response) = try await LLMAPITransport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgentRuntimeTransportError.invalidHTTPResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let details = String(data: data, encoding: .utf8) ?? ""
            throw AgentRuntimeTransportError.requestFailed(httpResponse.statusCode, details)
        }
    }

    private func resetWebSocket() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        connectedWebSocketURL = nil
    }
}

extension AgentRuntimeEvent.ProviderMetadata {
    static func from(apiBaseURL: String, providerKind: AgentProviderKind) -> Self {
        let normalized = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider: String

        switch providerKind {
        case .automatic:
            let components = URLComponents(string: normalized)
            let host = components?.host?.lowercased() ?? ""
            let path = components?.path.lowercased() ?? ""
            let hostParts = host.split(separator: ".").map(String.init)
            let pathParts = path.split(separator: "/").map(String.init)

            if hostParts.contains(AgentProviderKind.litellm.providerName) || pathParts.contains(AgentProviderKind.litellm.providerName) {
                provider = AgentProviderKind.litellm.providerName
            } else if hostParts.contains(AgentProviderKind.groq.providerName) || pathParts.contains(AgentProviderKind.groq.providerName) {
                provider = AgentProviderKind.groq.providerName
            } else if hostParts.contains(AgentProviderKind.ollama.providerName) || pathParts.contains(AgentProviderKind.ollama.providerName) {
                provider = AgentProviderKind.ollama.providerName
            } else {
                provider = AgentProviderKind.openAICompatible.providerName
            }
        default:
            provider = providerKind.providerName
        }

        return .init(
            apiBaseURL: normalized,
            provider: provider,
            isLiteLLM: provider == AgentProviderKind.litellm.providerName
        )
    }
}
