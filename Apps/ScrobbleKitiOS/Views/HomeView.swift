import ScrobbleCore
import SwiftData
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Query private var records: [ScrobbleRecord]
    @State private var showingSettings = false

    init() {
        var descriptor = FetchDescriptor<ScrobbleRecord>(sortBy: [SortDescriptor(\.listenedAt, order: .reverse)])
        descriptor.fetchLimit = 100
        _records = Query(descriptor)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusCard()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                if let track = model.nowPlaying {
                    Section("Now Playing") {
                        NowPlayingRow(track: track)
                    }
                }

                Section {
                    if records.isEmpty {
                        ContentUnavailableView(
                            "No Scrobbles Yet", systemImage: "waveform",
                            description: Text("Play something in Apple Music. Plays show up here once they count.")
                        )
                    } else {
                        ForEach(records) { record in
                            ScrobbleRowView(record: record, artworkSize: 42)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { model.delete(record) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    if !record.isFullySent {
                                        Button { model.retry(record) } label: {
                                            Label("Retry", systemImage: "arrow.clockwise")
                                        }
                                        .tint(.blue)
                                    }
                                }
                        }
                    }
                } header: {
                    Text("Recent Scrobbles")
                } footer: {
                    Text("iPhone apps can't watch Apple Music all the time. ScrobbleKit catches plays while it's open, when iOS lets it check in the background, and whenever your Sync Scrobbles shortcut runs. Expect roughly 85–95% of plays.")
                }
            }
            .listStyle(.insetGrouped)
            .animation(.smooth, value: records.map(\.id))
            .animation(.smooth, value: model.nowPlaying?.id)
            .navigationTitle("ScrobbleKit")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .refreshable { await model.sync() }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
    }
}

private struct StatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = model.summary
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                StatusDot(summary.level)
                Text(summary.headline)
                    .font(.headline)
                    .contentTransition(.opacity)
                Spacer()
            }

            HStack(spacing: 8) {
                ServiceChip(name: "Last.fm", connected: model.lastfmUser != nil, state: model.queue.status.lastfm)
                ServiceChip(name: "ListenBrainz", connected: model.listenbrainzUser != nil, state: model.queue.status.listenbrainz)
            }

            HStack(alignment: .firstTextBaseline) {
                if let lastSync = model.lastSync {
                    (Text("Synced ") + Text(lastSync, style: .relative) + Text(" ago"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not synced yet").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.sync() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isSyncing {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text("Sync Now")
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(model.isSyncing)
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.background.secondary)
                .overlay(alignment: .topTrailing) {
                    LinearGradient(colors: [summary.level.color.opacity(0.25), .clear],
                                   startPoint: .topTrailing, endPoint: .bottomLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
        }
        .animation(.smooth, value: summary)
    }
}

private struct ServiceChip: View {
    let name: String
    let connected: Bool
    let state: ServiceState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connected ? state.level.color : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(name).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.7), in: Capsule())
        .accessibilityLabel(Text("\(name): \(connected ? state.label : "not connected")"))
    }
}

private struct NowPlayingRow: View {
    @Environment(AppModel.self) private var model
    let track: PlayingTrack

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(releaseMBID: model.nowPlayingReleaseMBID, size: 56)
                .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.headline).lineLimit(1)
                Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Group {
                    if model.nowPlayingScrobbled {
                        Label("Scrobbled", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if track.isPodcast {
                        Label("Podcasts aren't scrobbled", systemImage: "mic").foregroundStyle(.secondary)
                    } else if model.isPlaying {
                        Label("Listening", systemImage: "waveform")
                            .symbolEffect(.variableColor.iterative, isActive: true)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Paused", systemImage: "pause.fill").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }
}
