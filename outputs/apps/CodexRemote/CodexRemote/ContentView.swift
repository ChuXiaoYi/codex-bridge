import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: RelaySettings
    @EnvironmentObject private var store: ThreadsStore
    @EnvironmentObject private var notifications: NotificationRegistrar
    @EnvironmentObject private var events: EventStreamStore

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    Picker("Backend", selection: $settings.backendRaw) {
                        ForEach(RemoteBackend.allCases) { backend in
                            Text(backend.label).tag(backend.rawValue)
                        }
                    }
                    HStack {
                        Button("Refresh") {
                            Task { await store.refresh(using: settings) }
                        }
                        Spacer()
                        ProgressView()
                            .opacity(store.isLoading ? 1 : 0)
                    }
                    Text(store.statusMessage)
                        .foregroundStyle(.secondary)
                }

                if settings.backend == .relay {
                    Section("Relay") {
                        TextField("Relay URL", text: $settings.relayURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        SecureField("Client token", text: $settings.clientToken)
                            .textInputAutocapitalization(.never)
                    }

                    Section("Notifications") {
                        Button("Enable Completion Alerts") {
                            Task { await notifications.enable(using: settings) }
                        }
                        Text(notifications.status)
                            .foregroundStyle(.secondary)
                        if !settings.lastDeviceToken.isEmpty {
                            Text(settings.lastDeviceToken)
                                .font(.caption2.monospaced())
                                .lineLimit(2)
                        }
                    }

                    Section("Events") {
                        HStack {
                            Button(events.isStreaming ? "Stop Events" : "Connect Events") {
                                if events.isStreaming {
                                    events.stop()
                                } else {
                                    events.start(using: settings)
                                }
                            }
                            Spacer()
                            if events.isStreaming {
                                ProgressView()
                            }
                        }
                        Text(events.status)
                            .foregroundStyle(.secondary)
                        ForEach(events.events.reversed()) { event in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.type)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Text(event.summary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } else {
                    Section("GitHub") {
                        TextField("API URL", text: $settings.githubAPIURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        TextField("Owner", text: $settings.githubOwner)
                            .textInputAutocapitalization(.never)
                        TextField("Repo", text: $settings.githubRepo)
                            .textInputAutocapitalization(.never)
                        TextField("Label", text: $settings.githubLabel)
                            .textInputAutocapitalization(.never)
                        SecureField("GitHub token", text: $settings.githubToken)
                            .textInputAutocapitalization(.never)
                    }
                }

                Section("New Task") {
                    TextField("Ask Codex to do something", text: $store.newTaskText, axis: .vertical)
                        .lineLimit(2...5)
                    if settings.backend == .relay {
                        Toggle("Ephemeral", isOn: $store.ephemeralNewTasks)
                    }
                    Button("Send Task") {
                        Task { await store.createThread(using: settings) }
                    }
                    .disabled(store.newTaskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section(settings.backend == .github ? "GitHub Issues" : "Threads") {
                    ForEach(store.threads) { thread in
                        NavigationLink(value: thread) {
                            ThreadRow(thread: thread)
                        }
                    }
                }
            }
            .navigationTitle("Codex Remote")
            .navigationDestination(for: CodexThread.self) { thread in
                ThreadDetailView(thread: thread)
                    .environmentObject(settings)
                    .environmentObject(store)
            }
            .task {
                await store.refresh(using: settings)
            }
        }
    }
}

struct ThreadRow: View {
    let thread: CodexThread

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(thread.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(thread.statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(thread.preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

struct ThreadDetailView: View {
    let thread: CodexThread

    @EnvironmentObject private var settings: RelaySettings
    @EnvironmentObject private var store: ThreadsStore
    @State private var message = ""

    var body: some View {
        List {
            Section("Thread") {
                Text(thread.name)
                    .font(.headline)
                Text(thread.preview)
                    .foregroundStyle(.secondary)
                if let cwd = thread.cwd {
                    Text(cwd)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Section("Continue") {
                TextField("Add an instruction", text: $message, axis: .vertical)
                    .lineLimit(2...6)
                Button(settings.backend == .github ? "Comment" : "Send / Steer") {
                    let outgoing = message
                    message = ""
                    Task {
                        await store.sendMessage(outgoing, to: thread, using: settings)
                    }
                }
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section("Status") {
                Text(store.statusMessage)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
    }
}
