import ScrobbleCore
import SwiftUI

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            LastFMPane()
                .tabItem { Label("Last.fm", systemImage: "dot.radiowaves.left.and.right") }
            ListenBrainzPane()
                .tabItem { Label("ListenBrainz", systemImage: "headphones") }
            RecentScrobblesView()
                .tabItem { Label("Scrobbles", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 560, height: 460)
    }
}

private struct GeneralPane: View {
    @Environment(MenuBarController.self) private var controller
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section {
                Toggle("Open ScrobbleKit at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in controller.launchesAtLogin = newValue }
            }
            Section {
                Toggle("Ignore other devices", isOn: .constant(true))
                    .disabled(true)
                Text("Always on here. Music on the Mac only reports this Mac's playback, so plays from your iPhone, HomePod or other devices never reach this app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("When a track counts") {
                Text("A track is scrobbled once it has played for half its length or 4 minutes, whichever comes first. Tracks of 30 seconds or less are never scrobbled. Every scrobble goes to both Last.fm and ListenBrainz.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Version", value: Self.version)
                Link("ScrobbleKit on GitHub", destination: URL(string: "https://github.com/urazalievf/scrobblekit")!)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = controller.launchesAtLogin }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

private struct LastFMPane: View {
    @Environment(MenuBarController.self) private var controller

    var body: some View {
        Form {
            if controller.lastfmAPIKey == nil {
                Section {
                    Label("This build has no Last.fm API key", systemImage: "key.slash")
                        .foregroundStyle(.orange)
                    Text("Add LASTFM_API_KEY and LASTFM_SHARED_SECRET to the .env file at the root of the repository, then build again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                if controller.queue.status.lastfm == .suspended {
                    Section {
                        Label("Last.fm suspended this app's API key", systemImage: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.headline)
                        Text("Last.fm answered with error 26, so scrobbling to Last.fm has stopped. Plays are still saved and still go to ListenBrainz. Once the key is sorted out (or replaced in .env), turn Last.fm back on.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Turn Last.fm Back On") { controller.clearLastFMSuspension() }
                    }
                }
                Section {
                    if let user = controller.lastfmUser {
                        LabeledContent("Account", value: user)
                        LabeledContent("Status") {
                            HStack(spacing: 6) {
                                StatusDot(controller.queue.status.lastfm.level)
                                Text(controller.queue.status.lastfm.label)
                            }
                        }
                        Button("Log Out", role: .destructive) { controller.logOutLastFM() }
                    } else {
                        Button("Log In with Last.fm…") { controller.startLastFMLogin() }
                            .buttonStyle(.borderedProminent)
                        Text("Your browser opens Last.fm. Approve ScrobbleKit there and you come straight back here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error = controller.lastfmLoginError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ListenBrainzPane: View {
    @Environment(MenuBarController.self) private var controller
    @State private var token = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                if let user = controller.listenbrainzUser {
                    LabeledContent("Account", value: user)
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            StatusDot(controller.queue.status.listenbrainz.level)
                            Text(controller.queue.status.listenbrainz.label)
                        }
                    }
                    Button("Disconnect", role: .destructive) { controller.disconnectListenBrainz() }
                } else {
                    SecureField("User token", text: $token)
                        .onSubmit(connect)
                    HStack {
                        Button("Connect", action: connect)
                            .buttonStyle(.borderedProminent)
                            .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
                        if isConnecting { ProgressView().controlSize(.small) }
                    }
                    Link("Copy your token from listenbrainz.org/settings",
                         destination: URL(string: "https://listenbrainz.org/settings/")!)
                        .font(.caption)
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            } footer: {
                Text("The token is checked with ListenBrainz, then kept in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func connect() {
        isConnecting = true
        error = nil
        Task {
            do {
                try await controller.connectListenBrainz(token: token)
                token = ""
            } catch ListenBrainzError.invalidToken {
                error = "ListenBrainz didn't accept that token."
            } catch {
                self.error = "Couldn't reach ListenBrainz: \(error.localizedDescription)"
            }
            isConnecting = false
        }
    }
}
