import Foundation

struct GitHubAPI {
    var apiURL: URL
    var owner: String
    var repo: String
    var token: String
    var label: String
    var doneLabel: String
    var session: URLSession = .shared

    func listIssues(limit: Int = 20) async throws -> [CodexThread] {
        guard !owner.isEmpty, !repo.isEmpty else {
            throw GitHubAPIError.missingRepository
        }

        var components = URLComponents(url: repoURL("issues"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "state", value: "open"),
            URLQueryItem(name: "labels", value: label),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "per_page", value: String(limit)),
        ]
        let issues: [GitHubIssue] = try await request(components?.url ?? repoURL("issues"))
        return issues
            .filter { $0.pullRequest == nil }
            .filter { !$0.hasLabel(doneLabel) }
            .map { $0.codexThread }
    }

    func createIssue(text: String) async throws {
        guard !owner.isEmpty, !repo.isEmpty else {
            throw GitHubAPIError.missingRepository
        }
        let title = GitHubAPI.issueTitle(from: text)
        let body = GitHubCreateIssueRequest(title: title, body: text, labels: [label])
        let _: GitHubIssue = try await request(repoURL("issues"), method: "POST", body: body)
    }

    func addComment(issueNumber: String, text: String) async throws {
        guard !owner.isEmpty, !repo.isEmpty else {
            throw GitHubAPIError.missingRepository
        }
        guard Int(issueNumber) != nil else {
            throw GitHubAPIError.invalidIssueNumber
        }
        let body = GitHubCreateCommentRequest(body: text)
        let _: GitHubIssueComment = try await request(
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw GitHubAPIError.http(status: http.statusCode, message: message)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

struct GitHubIssue: Decodable {
    let id: Int
    let number: Int
    let title: String
    let body: String?
    let state: String
    let updatedAt: String?
    let pullRequest: JSONValue?
    let labels: [GitHubLabel]?

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case title
        case body
        case state
        case updatedAt = "updated_at"
        case pullRequest = "pull_request"
        case labels
    }

    func hasLabel(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return labels?.contains { $0.name == trimmed } ?? false
    }

    var codexThread: CodexThread {
        CodexThread(
            id: String(number),
            name: title,
            preview: body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            previewTruncated: false,
            cwd: nil,
            status: .object(["type": .string("github issue")]),
            ephemeral: false,
            updatedAt: updatedAt.flatMap { ISO8601DateFormatter.githubDate(from: $0)?.timeIntervalSince1970 }
        )
    }
}

struct GitHubLabel: Decodable {
    let name: String
}

struct GitHubIssueComment: Decodable {
    let id: Int
    let body: String?
}

struct GitHubCreateIssueRequest: Encodable {
    let title: String
    let body: String
    let labels: [String]
}

struct GitHubCreateCommentRequest: Encodable {
    let body: String
}

enum GitHubAPIError: LocalizedError {
    case missingRepository
    case invalidIssueNumber
    case invalidResponse
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingRepository:
            return "Set GitHub owner and repository first."
        case .invalidIssueNumber:
            return "This GitHub issue number is invalid."
        case .invalidResponse:
            return "GitHub returned an invalid response."
        case .http(let status, let message):
            return "GitHub HTTP \(status): \(message)"
        }
    }
}

extension ISO8601DateFormatter {
    static func githubDate(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}
