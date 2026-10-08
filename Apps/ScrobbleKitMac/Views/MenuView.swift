import ScrobbleCore
import SwiftData
import SwiftUI

/// The menu bar popover: now playing, status, the last few scrobbles, and
/// Sync / Preferences / Quit.
struct MenuView: View {
    @Environment(MenuBarController.self) private var controller
    @Environment(\.openSettings) private var openSettings
    @Query private var recent: [ScrobbleRecord]

    init() {
        var descriptor = FetchDescriptor<ScrobbleRecord>(sortBy: [SortDescriptor(\.listenedAt, order: .reverse)])
        descriptor.fetchLimit = 5
        _recent = Query(descriptor)
    }

    var body: some View {
        VStack(spacing: 0) {
            NowPlayingCard()
                .padding(14)
            Divider()
            StatusSection()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            recentSection
            Divider()
            footer
        }
        .frame(width: 340)
        .animation(.smooth(duration: 0.3), value: controller.nowPlaying?.id)
        .animation(.smooth(duration: 0.3), value: recent.map(\.id))
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent scrobbles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if recent.isEmpty {
                Text("Nothing scrobbled yet. Play something in Music.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(recent) { record in
                    ScrobbleRowView(record: record, artworkSize: 30)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                Task { await controller.syncNow() }
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    .symbolEffect(.pulse, isActive: controller.isSyncing)
            }
            .disabled(controller.isSyncing)

            Spacer()

            Button("Preferences…") {
                NSApp.activate()
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct NowPlayingCard: View {
    @Environment(MenuBarController.self) private var controller

    var body: some View {
        HStack(spacing: 12) {
            if let track = controller.nowPlaying {
                ArtworkView(releaseMBID: controller.nowPlayingReleaseMBID, size: 64)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    .id(track.id)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let album = track.album {
                        Text(album)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    playbackLine(for: track)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, height: 64)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nothing playing")
                        .font(.headline)
                    Text("Play something in Music and it shows up here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func playbackLine(for track: PlayingTrack) -> some View {
        if controller.nowPlayingScrobbled {
            Label("Scrobbled", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption.weight(.medium))
                .transition(.opacity)
        } else if track.isPodcast {
            Label("Podcasts aren't scrobbled", systemImage: "mic")
                .foregroundStyle(.secondary)
                .font(.caption)
        } else if controller.isPlaying {
            Label(scrobbleHint(for: track), systemImage: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: true)
                .foregroundStyle(.secondary)
                .font(.caption)
        } else {
            Label("Paused", systemImage: "pause.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private func scrobbleHint(for track: PlayingTrack) -> String {
        guard let duration = track.durationSec else { return "Scrobbles after 4:00" }
        guard duration > PlaybackTracker.minimumDuration else { return "Too short to scrobble" }
        let seconds = Int(min(Double(duration) / 2, PlaybackTracker.maximumRequiredPlay))
        return "Scrobbles after \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct StatusSection: View {
    @Environment(MenuBarController.self) private var controller

    var body: some View {
        let summary = controller.summary
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(summary.level)
                Text(summary.headline)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .contentTransition(.opacity)
                Spacer()
            }
            HStack(spacing: 6) {
                ServicePill(
                    name: "Last.fm",
                    connected: controller.lastfmUser != nil,
                    state: controller.queue.status.lastfm
                )
                ServicePill(
                    name: "ListenBrainz",
                    connected: controller.listenbrainzUser != nil,
                    state: controller.queue.status.listenbrainz
                )
                Spacer()
                if controller.pendingCount > 0 {
                    Text("\(controller.pendingCount) queued")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
        }
        .animation(.smooth, value: summary)
        .animation(.smooth, value: controller.pendingCount)
    }
}

private struct ServicePill: View {
    let name: String
    let connected: Bool
    let state: ServiceState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(connected ? state.level.color : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(name)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: Capsule())
        .help(connected ? "\(name): \(state.label)" : "\(name): not connected")
    }
}
