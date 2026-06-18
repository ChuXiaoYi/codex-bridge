import Foundation

@MainActor
final class EventStreamStore: ObservableObject {
    @Published private(set) var events: [RelayEvent] = []
    @Published private(set) var isStreaming = false
    @Published var status = "Events disconnected"

    private var streamTask: Task<Void, Never>?

    func start(using settings: RelaySettings) {
        stop()
        guard let baseURL = settings.normalizedRelayURL else {
            status = "Set a valid Relay URL"
            return
        }

        isStreaming = true
        status = "Connecting events"
        let token = settings.clientToken
        streamTask = Task {
            await run(baseURL: baseURL, token: token)
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        status = "Events disconnected"
    }

    private func run(baseURL: URL, token: String) async {
        var request = URLRequest(url: baseURL.appending(path: "events"))
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedToken.isEmpty {
            request.setValue("Bearer \(trimmedToken)", forHTTPHeaderField: "authorization")
        }

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                await updateStatus("Relay events failed")
                return
            }

            await updateStatus("Events connected")
            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard line.hasPrefix("data:") else { continue }
                let json = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                await ingest(json)
            }
        } catch {
            if !Task.isCancelled {
                await updateStatus(error.localizedDescription)
            }
        }

        await MainActor.run {
            isStreaming = false
        }
    }

    private func ingest(_ json: String) async {
        guard let data = json.data(using: .utf8) else { return }
        let decoder = JSONDecoder()

        if let connected = try? decoder.decode(RelayConnectedEvent.self, from: data) {
            await MainActor.run {
                events = Array(connected.recentEvents.suffix(20))
            }
            return
        }

        if let event = try? decoder.decode(RelayEvent.self, from: data) {
            await MainActor.run {
                events.append(event)
                if events.count > 20 {
                    events.removeFirst(events.count - 20)
                }
            }
        }
    }

    private func updateStatus(_ message: String) async {
        await MainActor.run {
            status = message
        }
    }
}
