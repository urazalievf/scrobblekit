import AuthenticationServices
import ScrobbleCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var token = ""
    @State private var isConnecting = false
    @State private var listenbrainzError: String?
    @State private var lastfmError: String?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                lastfmSection
                listenbrainzSection

                Section {
                    Toggle("Ignore other devices", isOn: $model.ignoreOtherDevices)
                } header: {
                    Text("Capture")
                } footer: {
                    Text("Recently Played covers every device on your Apple ID and doesn't say which one played a song. With this on, a play that already appears in your ListenBrainz history (for example because ScrobbleKit on your Mac sent it) is skipped. This check needs ListenBrainz connected. Plays from devices that don't scrobble, like a HomePod, are still picked up.")
                }

                Section {
                    LabeledContent("Apple Music access", value: model.musicAuthorized ? "Allowed" : "Not allowed")
                    if !model.musicAuthorized {
                        Button("Allow Apple Music Access") { Task { await model.requestMusicAccess() } }
                    }
                } header: {
                    Text("Background")
                } footer: {
                    Text("For better coverage, open Shortcuts → Automation → New Automation → Time of Day, repeat hourly, and add the “Sync Scrobbles” action from ScrobbleKit.")
                }

                Section {
                    LabeledContent("Version", value: Self.version)
                    Link("ScrobbleKit on GitHub", destination: URL(string: "https://github.com/urazalievf/scrobblekit")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var lastfmSection: some View {
        Section {
            if let key = model.lastfmAPIKey {
                if model.queue.status.lastfm == .suspended {
                    Label("Last.fm suspended this app's API key", systemImage: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    Button("Turn Last.fm Back On") { model.clearLastFMSuspension() }
                }
                if let user = model.lastfmUser {
                    LabeledContent("Account", value: user)
                    LabeledContent("Status", value: model.queue.status.lastfm.label)
                    Button("Log Out", role: .destructive) { model.logOutLastFM() }
                } else {
                    Button("Log In with Last.fm") { logInToLastFM(apiKey: key) }
                }
                if let lastfmError {
                    Text(lastfmError).font(.footnote).foregroundStyle(.red)
                }
            } else {
                Label("This build has no Last.fm API key", systemImage: "key.slash")
                    .foregroundStyle(.orange)
                Text("Add LASTFM_API_KEY and LASTFM_SHARED_SECRET to .env and build again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Last.fm")
        }
    }

    @ViewBuilder
    private var listenbrainzSection: some View {
        Section {
            if let user = model.listenbrainzUser {
                LabeledContent("Account", value: user)
                LabeledContent("Status", value: model.queue.status.listenbrainz.label)
                Button("Disconnect", role: .destructive) { model.disconnectListenBrainz() }
            } else {
                SecureField("User token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    connectListenBrainz()
                } label: {
                    HStack {
                        Text("Connect")
                        if isConnecting { Spacer(); ProgressView() }
                    }
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
                Link("Copy your token from listenbrainz.org/settings",
                     destination: URL(string: "https://listenbrainz.org/settings/")!)
                    .font(.footnote)
                if let listenbrainzError {
                    Text(listenbrainzError).font(.footnote).foregroundStyle(.red)
                }
            }
        } header: {
            Text("ListenBrainz")
        } footer: {
            Text("Tokens and session keys are kept in the Keychain.")
        }
    }

    private func logInToLastFM(apiKey: String) {
        lastfmError = nil
        Task {
            do {
                let callback = try await webAuthenticationSession.authenticate(
                    using: LastFMAuth.authorizationURL(apiKey: apiKey),
                    callbackURLScheme: LastFMAuth.callbackScheme
                )
                try await model.completeLastFMLogin(callbackURL: callback)
            } catch ASWebAuthenticationSessionError.canceledLogin {
                // The user closed the sheet.
            } catch {
                lastfmError = "Last.fm login failed: \(error.localizedDescription)"
            }
        }
    }

    private func connectListenBrainz() {
        isConnecting = true
        listenbrainzError = nil
        Task {
            do {
                try await model.connectListenBrainz(token: token)
                token = ""
            } catch ListenBrainzError.invalidToken {
                listenbrainzError = "ListenBrainz didn't accept that token."
            } catch {
                listenbrainzError = "Couldn't reach ListenBrainz: \(error.localizedDescription)"
            }
            isConnecting = false
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
