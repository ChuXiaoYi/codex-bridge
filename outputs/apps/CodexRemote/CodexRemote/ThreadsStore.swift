import Foundation

@MainActor
final class ThreadsStore: ObservableObject {
    @Published private(set) var threads: [CodexThread] = []
    @Published var newTaskText = ""
    @Published var ephemeralNewTasks = false
    @Published var isLoading = false
    @Published var statusMessage = "Not connected"

    func refresh(using settings: RelaySettings) async {
        isLoading = true
        defer { isLoading = false }

        do {
            switch settings.backend {
            case .relay:
                guard let api = makeRelayAPI(settings: settings) else {
                    statusMessage = "Set a valid Relay URL"
                    return
                }
                threads = try await api.listThreads()
                statusMessage = "Loaded \(threads.count) threads"
            case .github:
                guard let api = makeGitHubAPI(settings: settings) else {
                    statusMessage = "Set a valid GitHub API URL"
                    return
                }
                threads = try await api.listIssues()
                statusMessage = "Loaded \(threads.count) issues"
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func createThread(using settings: RelaySettings) async {
        let text = newTaskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusMessage = "Type a task first"
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            switch settings.backend {
            case .relay:
                guard let api = makeRelayAPI(settings: settings) else {
                    statusMessage = "Set a valid Relay URL"
                    return
                }
                try await api.createThread(text: text, ephemeral: ephemeralNewTasks)
            case .github:
                guard let api = makeGitHubAPI(settings: settings) else {
                    statusMessage = "Set a valid GitHub API URL"
                    return
                }
                try await api.createIssue(text: text)
            }
            newTaskText = ""
            statusMessage = "Task sent"
            await refresh(using: settings)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func sendMessage(_ text: String, to thread: CodexThread, using settings: RelaySettings) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            statusMessage = "Type an instruction first"
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            switch settings.backend {
            case .relay:
                guard let api = makeRelayAPI(settings: settings) else {
                    statusMessage = "Set a valid Relay URL"
                    return
                }
                try await api.sendMessage(threadId: thread.id, text: trimmed)
                statusMessage = "Instruction sent"
            case .github:
                guard let api = makeGitHubAPI(settings: settings) else {
                    statusMessage = "Set a valid GitHub API URL"
                    return
                }
                try await api.addComment(issueNumber: thread.id, text: trimmed)
                statusMessage = "Comment sent"
            }
            await refresh(using: settings)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func makeRelayAPI(settings: RelaySettings) -> RelayAPI? {
        guard let url = settings.normalizedRelayURL else { return nil }
        return RelayAPI(baseURL: url, clientToken: settings.clientToken)
    }

    private func makeGitHubAPI(settings: RelaySettings) -> GitHubAPI? {
        guard let url = settings.normalizedGitHubAPIURL else { return nil }
        return GitHubAPI(
            apiURL: url,
            owner: settings.githubOwner.trimmingCharacters(in: .whitespacesAndNewlines),
            repo: settings.githubRepo.trimmingCharacters(in: .whitespacesAndNewlines),
            token: settings.githubToken,
            label: settings.githubLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "codex-remote"
                : settings.githubLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
