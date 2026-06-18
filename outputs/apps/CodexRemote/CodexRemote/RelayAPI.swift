import Foundation

struct RelayAPI {
    var baseURL: URL
    var clientToken: String
    var session: URLSession = .shared

    func listThreads(limit: Int = 20) async throws -> [CodexThread] {
        var components = URLComponents(url: baseURL.appending(path: "threads"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        let response: ThreadListResponse = try await request(components?.url ?? baseURL.appending(path: "threads"))
        return response.data
    }

    func createThread(text: String, ephemeral: Bool) async throws {
        let body = CreateThreadRequest(text: text, ephemeral: ephemeral, threadSource: "codex-remote-ios")
        let _: JSONValue = try await request(
            baseURL.appending(path: "threads"),
            method: "POST",
            body: body
        )
    }

    func sendMessage(threadId: String, text: String) async throws {
        let body = SendMessageRequest(
            text: text,
            responsesapiClientMetadata: [
                "source": "codex-remote-ios"
            ]
        )
        let _: JSONValue = try await request(
            baseURL.appending(path: "threads").appending(path: threadId).appending(path: "messages"),
            method: "POST",
            body: body
        )
    }

    func registerDevice(token: String, platform: String) async throws {
        let body = RelayDeviceRegistration(token: token, platform: platform, appName: "CodexRemote")
        let _: JSONValue = try await request(
            baseURL.appending(path: "devices"),
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RelayAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw RelayAPIError.http(status: http.statusCode, message: message)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

enum RelayAPIError: LocalizedError {
    case invalidResponse
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Relay returned an invalid response."
        case .http(let status, let message):
            return "Relay HTTP \(status): \(message)"
        }
    }
}
