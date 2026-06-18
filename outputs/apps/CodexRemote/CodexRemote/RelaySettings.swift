import Foundation
@preconcurrency import WatchConnectivity

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
final class RelaySettings: NSObject, ObservableObject, WCSessionDelegate {
    @Published var backendRaw: String {
        didSet {
            defaults.set(backendRaw, forKey: Keys.backendRaw)
            scheduleWatchSettingsSync()
        }
    }

    @Published var relayURL: String {
        didSet {
            defaults.set(relayURL, forKey: Keys.relayURL)
            scheduleWatchSettingsSync()
        }
    }

    @Published var clientToken: String {
        didSet {
            defaults.set(clientToken, forKey: Keys.clientToken)
            scheduleWatchSettingsSync()
        }
    }

    @Published var lastDeviceToken: String {
        didSet { defaults.set(lastDeviceToken, forKey: Keys.lastDeviceToken) }
    }

    @Published var githubAPIURL: String {
        didSet {
            defaults.set(githubAPIURL, forKey: Keys.githubAPIURL)
            scheduleWatchSettingsSync()
        }
    }

    @Published var githubOwner: String {
        didSet {
            defaults.set(githubOwner, forKey: Keys.githubOwner)
            scheduleWatchSettingsSync()
        }
    }

    @Published var githubRepo: String {
        didSet {
            defaults.set(githubRepo, forKey: Keys.githubRepo)
            scheduleWatchSettingsSync()
        }
    }

    @Published var githubToken: String {
        didSet {
            defaults.set(githubToken, forKey: Keys.githubToken)
            scheduleWatchSettingsSync()
        }
    }

    @Published var githubLabel: String {
        didSet {
            defaults.set(githubLabel, forKey: Keys.githubLabel)
            scheduleWatchSettingsSync()
        }
    }

    @Published private(set) var watchSyncStatus = "Watch sync idle"

    private let defaults: UserDefaults
    private var watchSyncTask: Task<Void, Never>?

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
        super.init()
        configureWatchConnectivity()
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

    func syncWatchSettings(reason: String = "Manual sync") {
        guard WCSession.isSupported() else {
            watchSyncStatus = "Watch sync unavailable"
            return
        }

        let session = WCSession.default
        guard session.activationState == .activated else {
            watchSyncStatus = "Watch sync pending"
            return
        }
        guard session.isPaired else {
            watchSyncStatus = "No paired Watch"
            return
        }
        guard session.isWatchAppInstalled else {
            watchSyncStatus = "Install Watch app"
            return
        }

        let payload = watchSettingsPayload()
        do {
            try session.updateApplicationContext(payload)
            watchSyncStatus = "\(reason): queued"
        } catch {
            watchSyncStatus = error.localizedDescription
        }

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { [weak self] error in
                Task { @MainActor in
                    self?.watchSyncStatus = error.localizedDescription
                }
            }
        }
    }

    private func configureWatchConnectivity() {
        guard WCSession.isSupported() else {
            watchSyncStatus = "Watch sync unavailable"
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private func scheduleWatchSettingsSync() {
        watchSyncTask?.cancel()
        watchSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.syncWatchSettings(reason: "Settings changed")
        }
    }

    private func watchSettingsPayload() -> [String: String] {
        [
            "schemaVersion": "1",
            "backendRaw": backendRaw,
            "relayURL": relayURL,
            "clientToken": clientToken,
            "githubAPIURL": githubAPIURL,
            "githubOwner": githubOwner,
            "githubRepo": githubRepo,
            "githubToken": githubToken,
            "githubLabel": githubLabel,
            "syncedAt": String(Date().timeIntervalSince1970),
        ]
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let errorMessage = error?.localizedDescription
        Task { @MainActor [weak self] in
            if let errorMessage {
                self?.watchSyncStatus = errorMessage
            } else if activationState == .activated {
                self?.watchSyncStatus = "Watch sync ready"
                self?.syncWatchSettings(reason: "Initial sync")
            } else {
                self?.watchSyncStatus = "Watch sync inactive"
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.syncWatchSettings(reason: "Watch state changed")
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["command"] as? String == "syncSettings" else { return }
        Task { @MainActor [weak self] in
            self?.syncWatchSettings(reason: "Watch requested")
        }
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
