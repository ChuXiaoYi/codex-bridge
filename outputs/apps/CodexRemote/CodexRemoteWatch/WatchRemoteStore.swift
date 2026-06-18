import Foundation

enum RemoteBackend: String, CaseIterable, Identifiable {
    case relay
    case github

    var id: String { rawValue }

    var label: String {
        switch self {
        case .relay:
            return "Relay"
        case .github:
            return "GitHub"
        }
    }
}

@MainActor
final class WatchRemoteStore: ObservableObject {
    @Published var backendRaw: String {
        didSet { defaults.set(backendRaw, forKey: Keys.backendRaw) }
    }

    @Published var relayURL: String {
        didSet { defaults.set(relayURL, forKey: Keys.relayURL) }
    }

    @Published var clientToken: String {
        didSet { defaults.set(clientToken, forKey: Keys.clientToken) }
    }

    @Published var githubAPIURL: String {
        didSet { defaults.set(githubAPIURL, forKey: Keys.githubAPIURL) }
    }

    @Published var githubOwner: String {
        didSet { defaults.set(githubOwner, forKey: Keys.githubOwner) }
    }

    @Published var githubRepo: String {
        didSet { defaults.set(githubRepo, forKey: Keys.githubRepo) }
    }

    @Published var githubToken: String {
        didSet { defaults.set(githubToken, forKey: Keys.githubToken) }
    }

    @Published var githubLabel: String {
        didSet { defaults.set(githubLabel, forKey: Keys.githubLabel) }
    }

    @Published var taskText = ""
    @Published var status = "Ready"
    @Published var isSending = false
    @Published var isLoadingThreads = false
    @Published private(set) var threads: [WatchCodexThread] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.backendRaw = defaults.string(forKey: Keys.backendRaw) ?? RemoteBackend.relay.rawValue
        self.relayURL = defaults.string(forKey: Keys.relayURL) ?? "https://your-relay.example.com"
        self.clientToken = defaults.string(forKey: Keys.clientToken) ?? ""
        self.githubAPIURL = defaults.string(forKey: Keys.githubAPIURL) ?? "https://api.github.com"
        self.githubOwner = defaults.string(forKey: Keys.githubOwner) ?? ""
        self.githubRepo = defaults.string(forKey: Keys.githubRepo) ?? ""
        self.githubToken = defaults.string(forKey: Keys.githubToken) ?? ""
        self.githubLabel = defaults.string(forKey: Keys.githubLabel) ?? "codex-remote"
    }

    var backend: RemoteBackend {
        RemoteBackend(rawValue: backendRaw) ?? .relay
    }

    var isConfigured: Bool {
        switch backend {
        case .relay:
            return !relayURL.contains("your-relay.example.com") && normalizedRelayURL != nil
        case .github:
            return normalizedGitHubAPIURL != nil
                && !githubOwner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !githubRepo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func refreshThreads() async {
        isLoadingThreads = true
        defer { isLoadingThreads = false }

        do {
            switch backend {
            case .relay:
                guard let api = makeRelayAPI() else { return }
                threads = try await api.listThreads()
                status = threads.isEmpty ? "No threads yet" : "Updated"
            case .github:
                guard let api = makeGitHubAPI() else { return }
                threads = try await api.listIssues()
                status = threads.isEmpty ? "No issues yet" : "Updated"
            }
        } catch {
            status = error.localizedDescription
        }
    }

    func sendTask() async {
        let text = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            status = "Say or type a task"
            return
        }

        isSending = true
        defer { isSending = false }

        do {
            switch backend {
            case .relay:
                guard let api = makeRelayAPI() else { return }
                try await api.createThread(text: text)
            case .github:
                guard let api = makeGitHubAPI() else { return }
                try await api.createIssue(text: text)
            }
            taskText = ""
            status = "Sent"
            await refreshThreads()
        } catch {
            status = error.localizedDescription
        }
    }

    func sendMessage(_ message: String, to thread: WatchCodexThread) async {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            status = "Say or type an instruction"
            return
        }

        isSending = true
        defer { isSending = false }

        do {
            switch backend {
            case .relay:
                guard let api = makeRelayAPI() else { return }
                try await api.sendMessage(threadId: thread.id, text: text)
                status = "Instruction sent"
            case .github:
                guard let api = makeGitHubAPI() else { return }
                try await api.addComment(issueNumber: thread.id, text: text)
                status = "Comment sent"
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private var normalizedRelayURL: URL? {
        URL(string: relayURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private var normalizedGitHubAPIURL: URL? {
        URL(string: githubAPIURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func makeRelayAPI() -> WatchRelayAPI? {
        guard let baseURL = normalizedRelayURL else {
            status = "Bad Relay URL"
            return nil
        }
        return WatchRelayAPI(baseURL: baseURL, clientToken: clientToken)
    }

    private func makeGitHubAPI() -> WatchGitHubAPI? {
        guard let apiURL = normalizedGitHubAPIURL else {
            status = "Bad GitHub API URL"
            return nil
        }
        return WatchGitHubAPI(
            apiURL: apiURL,
            owner: githubOwner.trimmingCharacters(in: .whitespacesAndNewlines),
            repo: githubRepo.trimmingCharacters(in: .whitespacesAndNewlines),
            token: githubToken,
            label: githubLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "codex-remote"
                : githubLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private enum Keys {
        static let backendRaw = "backendRaw"
        static let relayURL = "relayURL"
        static let clientToken = "clientToken"
        static let githubAPIURL = "githubAPIURL"
        static let githubOwner = "githubOwner"
        static let githubRepo = "githubRepo"
        static let githubToken = "githubToken"
        static let githubLabel = "githubLabel"
    }
}

struct WatchThreadListResponse: Decodable {
    let data: [WatchCodexThread]
}

struct WatchCodexThread: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let preview: String
    let cwd: String?
    let status: WatchJSONValue?
    let ephemeral: Bool?
    let updatedAt: TimeInterval?

    var statusLabel: String {
        guard let status else { return "unknown" }
        if case let .object(values) = status, let type = values["type"] {
            return type.displayString
        }
        return status.displayString
    }
}

struct WatchCreateThreadRequest: Encodable {
    let text: String
    let ephemeral: Bool
    let threadSource: String
}

struct WatchSendMessageRequest: Encodable {
    let text: String
    let responsesapiClientMetadata: [String: String]
}

struct WatchRelayAPI {
    var baseURL: URL
    var clientToken: String

    func listThreads(limit: Int = 8) async throws -> [WatchCodexThread] {
        var components = URLComponents(url: baseURL.appending(path: "threads"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        let response: WatchThreadListResponse = try await request(components?.url ?? baseURL.appending(path: "threads"))
        return response.data
    }

    func createThread(text: String) async throws {
        let body = WatchCreateThreadRequest(
            text: text,
            ephemeral: false,
            threadSource: "codex-remote-watch"
        )
        let _: WatchJSONValue = try await request(
            baseURL.appending(path: "threads"),
            method: "POST",
            body: body
        )
    }

    func sendMessage(threadId: String, text: String) async throws {
        let body = WatchSendMessageRequest(
            text: text,
            responsesapiClientMetadata: [
                "source": "codex-remote-watch"
            ]
        )
        let _: WatchJSONValue = try await request(
            baseURL.appending(path: "threads").appending(path: threadId).appending(path: "messages"),
            method: "POST",
            body: body
        )
    }

    private func request<Response: Decodable>(_ url: URL, method: String = "GET") async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        addAuthHeaders(to: &request)
        return try await perform(request)
    }

    private func request<Body: Encodable, Response: Decodable>(
        _ url: URL,
        method: String,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        addAuthHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func addAuthHeaders(to request: inout URLRequest) {
        let token = clientToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        }
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WatchRelayError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw WatchRelayError.http(status: http.statusCode, message: message)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

struct WatchGitHubAPI {
    var apiURL: URL
    var owner: String
    var repo: String
    var token: String
    var label: String

    func listIssues(limit: Int = 8) async throws -> [WatchCodexThread] {
        guard !owner.isEmpty, !repo.isEmpty else {
            throw WatchRelayError.missingGitHubRepository
        }
        var components = URLComponents(url: repoURL("issues"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "labels", value: label),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "per_page", value: String(limit)),
        ]
        let issues: [WatchGitHubIssue] = try await request(components?.url ?? repoURL("issues"))
        return issues.filter { $0.pullRequest == nil }.map { $0.codexThread }
    }

    func createIssue(text: String) async throws {
        guard !owner.isEmpty, !repo.isEmpty else {
            throw WatchRelayError.missingGitHubRepository
        }
        let body = WatchGitHubCreateIssueRequest(
            title: WatchGitHubAPI.issueTitle(from: text),
            body: text,
            labels: [label]
        )
        let _: WatchGitHubIssue = try await request(repoURL("issues"), method: "POST", body: body)
    }

    func addComment(issueNumber: String, text: String) async throws {
        guard Int(issueNumber) != nil else {
            throw WatchRelayError.invalidGitHubIssueNumber
        }
        let body = WatchGitHubCreateCommentRequest(body: text)
        let _: WatchGitHubIssueComment = try await request(
            repoURL("issues/\(issueNumber)/comments"),
            method: "POST",
            body: body
        )
    }

    private func repoURL(_ path: String) -> URL {
        var url = apiURL
            .appending(path: "repos")
            .appending(path: owner)
            .appending(path: repo)
        for part in path.split(separator: "/") {
            url = url.appending(path: String(part))
        }
        return url
    }

    private static func issueTitle(from text: String) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = firstLine.isEmpty ? "Codex task" : firstLine
        return title.count > 80 ? "\(title.prefix(77))..." : title
    }

    private func request<Response: Decodable>(_ url: URL, method: String = "GET") async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        addHeaders(to: &request)
        return try await perform(request)
    }

    private func request<Body: Encodable, Response: Decodable>(
        _ url: URL,
        method: String,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        addHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func addHeaders(to request: inout URLRequest) {
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "x-github-api-version")
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "authorization")
        }
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WatchRelayError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw WatchRelayError.http(status: http.statusCode, message: message)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

struct WatchGitHubIssue: Decodable {
    let number: Int
    let title: String
    let body: String?
    let state: String
    let updatedAt: String?
    let pullRequest: WatchJSONValue?

    enum CodingKeys: String, CodingKey {
        case number
        case title
        case body
        case state
        case updatedAt = "updated_at"
        case pullRequest = "pull_request"
    }

    var codexThread: WatchCodexThread {
        WatchCodexThread(
            id: String(number),
            name: title,
            preview: body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            cwd: nil,
            status: .object(["type": .string("github issue")]),
            ephemeral: false,
            updatedAt: nil
        )
    }
}

struct WatchGitHubIssueComment: Decodable {
    let id: Int
    let body: String?
}

struct WatchGitHubCreateIssueRequest: Encodable {
    let title: String
    let body: String
    let labels: [String]
}

struct WatchGitHubCreateCommentRequest: Encodable {
    let body: String
}

enum WatchJSONValue: Decodable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: WatchJSONValue])
    case array([WatchJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([WatchJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: WatchJSONValue].self))
        }
    }

    var displayString: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .object(let value):
            return value.keys.sorted().joined(separator: ", ")
        case .array(let value):
            return "\(value.count) items"
        case .null:
            return "null"
        }
    }
}

enum WatchRelayError: LocalizedError {
    case invalidResponse
    case missingGitHubRepository
    case invalidGitHubIssueNumber
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Relay returned an invalid response."
        case .missingGitHubRepository:
            return "Set GitHub owner and repository first."
        case .invalidGitHubIssueNumber:
            return "This GitHub issue number is invalid."
        case .http(let status, let message):
            return "Relay HTTP \(status): \(message)"
        }
    }
}
