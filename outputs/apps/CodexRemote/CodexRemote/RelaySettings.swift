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
final class RelaySettings: ObservableObject {
    @Published var backendRaw: String {
        didSet { defaults.set(backendRaw, forKey: Keys.backendRaw) }
    }

    @Published var relayURL: String {
        didSet { defaults.set(relayURL, forKey: Keys.relayURL) }
    }

    @Published var clientToken: String {
        didSet { defaults.set(clientToken, forKey: Keys.clientToken) }
    }

    @Published var lastDeviceToken: String {
        didSet { defaults.set(lastDeviceToken, forKey: Keys.lastDeviceToken) }
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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.backendRaw = defaults.string(forKey: Keys.backendRaw) ?? RemoteBackend.relay.rawValue
        self.relayURL = defaults.string(forKey: Keys.relayURL) ?? "http://127.0.0.1:8788"
        self.clientToken = defaults.string(forKey: Keys.clientToken) ?? "client-dev"
        self.lastDeviceToken = defaults.string(forKey: Keys.lastDeviceToken) ?? ""
        self.githubAPIURL = defaults.string(forKey: Keys.githubAPIURL) ?? "https://api.github.com"
        self.githubOwner = defaults.string(forKey: Keys.githubOwner) ?? ""
        self.githubRepo = defaults.string(forKey: Keys.githubRepo) ?? ""
        self.githubToken = defaults.string(forKey: Keys.githubToken) ?? ""
        self.githubLabel = defaults.string(forKey: Keys.githubLabel) ?? "codex-remote"
    }

    var backend: RemoteBackend {
        RemoteBackend(rawValue: backendRaw) ?? .relay
    }

    var isGitHubMode: Bool {
        backend == .github
    }

    var normalizedRelayURL: URL? {
        URL(string: relayURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    var normalizedGitHubAPIURL: URL? {
        URL(string: githubAPIURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private enum Keys {
        static let backendRaw = "backendRaw"
        static let relayURL = "relayURL"
        static let clientToken = "clientToken"
        static let lastDeviceToken = "lastDeviceToken"
        static let githubAPIURL = "githubAPIURL"
        static let githubOwner = "githubOwner"
        static let githubRepo = "githubRepo"
        static let githubToken = "githubToken"
        static let githubLabel = "githubLabel"
    }
}
