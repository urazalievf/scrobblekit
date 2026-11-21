import ScrobbleCore
import SwiftUI

struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPane()
                .tabItem { Label("General", systemImage: "gearshape") }
            ListenBrainzPane()
                .tabItem { Label("ListenBrainz", systemImage: "headphones") }
            LastFMPane()
                .tabItem { Label("Last.fm", systemImage: "dot.radiowaves.left.and.right") }
            WeekPane()
                .tabItem { Label("This Week", systemImage: "chart.bar") }
            RecentScrobblesView()
                .tabItem { Label("Scrobbles", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 580, height: 520)
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
            OtherDevicesSection()
            Section("When a track counts") {
                Text("A track is scrobbled once it has played for half its length or 4 minutes, whichever comes first. Tracks of 30 seconds or less are never scrobbled. Every scrobble goes to ListenBrainz and Last.fm, whichever are connected; ListenBrainz also gets how long the track actually played.")
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
                    Text("Add LASTFM_API_KEY and LASTFM_SHARED_SECRET to the .env file at the root of the repository, then build again. Since December 1, 2026, the Last.fm account that owns the key needs Last.fm Pro. ListenBrainz works without any of this.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                if case .keyRejected(let code) = controller.queue.status.lastfm {
                    Section {
                        Label("Last.fm stopped accepting this app's API key", systemImage: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                            .font(.headline)
                        Text("Last.fm answered with error \(code), so scrobbling to Last.fm has stopped. Since December 1, 2026, Last.fm only accepts an API key whose owner has Last.fm Pro. Plays are still saved and still go to ListenBrainz. If you built ScrobbleKit yourself, the key in .env is yours: once its account has Pro (or the key is replaced), turn Last.fm back on.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Turn Last.fm Back On") { controller.resumeLastFM() }
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

/// "Catch plays from my other devices": the Mac reads the account's Recently
/// Played every few minutes, and says how much of its own listening Apple
/// listed there.
private struct OtherDevicesSection: View {
    @Environment(MenuBarController.self) private var controller

    var body: some View {
        Section {
            Toggle("Catch plays from my other devices", isOn: Binding(
                get: { controller.catchOtherDevices },
                set: { on in Task { await controller.setCatchOtherDevices(on) } }
            ))
            Text("Every 3 minutes while this Mac is awake, ScrobbleKit reads your Apple Music account's Recently Played, which includes your iPhone, iPad and CarPlay, and scrobbles what no device has sent yet. Times are estimated to within a few minutes, and a song replayed between checks counts once. Plays already in your ListenBrainz history, such as ones ScrobbleKit on iPhone sent, are skipped.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = controller.otherDevicesError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if controller.catchOtherDevices {
                LabeledContent("Last checked") {
                    if let last = controller.lastOtherDevicesCheck {
                        Text(last, format: .relative(presentation: .named))
                    } else {
                        Text("Not yet")
                    }
                }
                if let report = controller.captureReport, let percent = report.percent {
                    LabeledContent("Recently Played listed") {
                        Text("\(report.listed) of \(report.total) of this Mac's plays (\(percent)%)")
                            .monospacedDigit()
                    }
                    Text("Of the plays this Mac caught exactly in the last 7 days, the share Apple's Recently Played also listed: a measured figure for how much Recently Played–based capture (ScrobbleKit on iPhone, or this check) picks up.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Other devices")
        }
        .onAppear { controller.refreshCaptureReport() }
    }
}

private struct WeekPane: View {
    @Environment(MenuBarController.self) private var controller

    var body: some View {
        Form {
            Section {
                RecapView(summary: controller.recap, sentence: controller.recapSentence,
                          sourceLabel: controller.historySourceLabel, isLoading: controller.isLoadingRecap)
                    .padding(.vertical, 4)
            } footer: {
                HStack {
                    Text("Ask Siri “What did I listen to in ScrobbleKit” or “My top artists in ScrobbleKit”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") { Task { await controller.refreshRecap() } }
                        .disabled(controller.isLoadingRecap)
                }
            }
        }
        .formStyle(.grouped)
        .task { await controller.refreshRecap() }
    }
}
