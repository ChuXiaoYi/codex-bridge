import SwiftUI

struct WatchContentView: View {
    @EnvironmentObject private var store: WatchRemoteStore

    var body: some View {
        NavigationStack {
            Form {
                Section("Backend") {
                    Picker("Mode", selection: $store.backendRaw) {
                        ForEach(RemoteBackend.allCases) { backend in
                            Text(backend.label).tag(backend.rawValue)
                        }
                    }
                    Button("Request iPhone Settings") {
                        store.requestSettingsFromPhone()
                    }
                    Text(store.phoneSyncStatus)
                        .foregroundStyle(.secondary)
                }

                Section("Task") {
                    TextField("Speak or type", text: $store.taskText, axis: .vertical)
                        .lineLimit(2...5)
                    Button {
                        Task { await store.sendTask() }
                    } label: {
                        if store.isSending {
                            ProgressView()
                        } else {
                            Text("Send to Codex")
                        }
                    }
                    .disabled(store.taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section(store.backend == .github ? "Issues" : "Threads") {
                    Button {
                        Task { await store.refreshThreads() }
                    } label: {
                        if store.isLoadingThreads {
                            ProgressView()
                        } else {
                            Text("Refresh")
                        }
                    }

                    ForEach(store.threads) { thread in
                        NavigationLink(value: thread) {
                            WatchThreadRow(thread: thread)
                        }
                    }
                }

                if store.backend == .relay {
                    Section("Relay") {
                        TextField("URL", text: $store.relayURL)
                            .textInputAutocapitalization(.never)
                        SecureField("Token", text: $store.clientToken)
                            .textInputAutocapitalization(.never)
                    }
                } else {
                    Section("GitHub") {
                        TextField("Owner", text: $store.githubOwner)
                            .textInputAutocapitalization(.never)
                        TextField("Repo", text: $store.githubRepo)
                            .textInputAutocapitalization(.never)
                        TextField("Label", text: $store.githubLabel)
                            .textInputAutocapitalization(.never)
                        TextField("Done Label", text: $store.githubDoneLabel)
                            .textInputAutocapitalization(.never)
                        Toggle("Show Done", isOn: $store.githubShowDone)
                        SecureField("Token", text: $store.githubToken)
                            .textInputAutocapitalization(.never)
                    }
                }

                Section("Status") {
                    Text(store.status)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Codex")
            .navigationDestination(for: WatchCodexThread.self) { thread in
                WatchThreadDetailView(thread: thread)
                    .environmentObject(store)
            }
            .task {
                if store.isConfigured {
                    await store.refreshThreads()
                }
            }
        }
    }
}

struct WatchThreadRow: View {
    let thread: WatchCodexThread

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(thread.name)
                .font(.headline)
                .lineLimit(1)
            Text(thread.statusLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(thread.preview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

struct WatchThreadDetailView: View {
    let thread: WatchCodexThread

    @EnvironmentObject private var store: WatchRemoteStore
    @State private var message = ""

    var body: some View {
        Form {
            Section("Thread") {
                Text(thread.name)
                    .font(.headline)
                Text(thread.preview)
                    .foregroundStyle(.secondary)
                Text(thread.statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Continue") {
                TextField("Speak or type", text: $message, axis: .vertical)
                    .lineLimit(2...5)
                Button {
                    let outgoing = message
                    message = ""
                    Task {
                        await store.sendMessage(outgoing, to: thread)
                    }
                } label: {
                    if store.isSending {
                        ProgressView()
                    } else {
                        Text(store.backend == .github ? "Comment" : "Send")
                    }
                }
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("Status") {
                Text(store.status)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Thread")
    }
}
