import SwiftUI

extension StatusLevel {
    public var color: Color {
        switch self {
        case .good: .green
        case .attention: .yellow
        case .problem: .red
        }
    }
}

/// A coloured status dot with a soft glow.
public struct StatusDot: View {
    let level: StatusLevel

    public init(_ level: StatusLevel) {
        self.level = level
    }

    public var body: some View {
        Circle()
            .fill(level.color.gradient)
            .frame(width: 9, height: 9)
            .shadow(color: level.color.opacity(0.6), radius: 3)
            .animation(.smooth, value: level)
            .accessibilityLabel(Text(level == .good ? "OK" : level == .attention ? "Needs attention" : "Problem"))
    }
}

/// Album art from the Cover Art Archive, with a gradient placeholder while
/// loading or when there's no release.
public struct ArtworkView: View {
    let releaseMBID: String?
    let size: CGFloat
    let cornerRadius: CGFloat

    public init(releaseMBID: String?, size: CGFloat, cornerRadius: CGFloat? = nil) {
        self.releaseMBID = releaseMBID
        self.size = size
        self.cornerRadius = cornerRadius ?? size * 0.18
    }

    public var body: some View {
        ZStack {
            placeholder
            if let url = releaseMBID.flatMap(CoverArt.url(releaseMBID:)) {
                AsyncImage(url: url, transaction: Transaction(animation: .smooth(duration: 0.35))) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill).transition(.opacity)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Color(red: 1.0, green: 0.18, blue: 0.33), Color(red: 0.37, green: 0.36, blue: 0.90)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "music.note")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        )
    }
}

/// Per-service send state for one record.
public struct ServiceBadge: View {
    let name: String
    let sent: Bool
    let failed: Bool

    public init(name: String, sent: Bool, failed: Bool) {
        self.name = name
        self.sent = sent
        self.failed = failed
    }

    public var body: some View {
        Image(systemName: sent ? "checkmark.circle.fill" : failed ? "xmark.circle.fill" : "clock.fill")
            .foregroundStyle(sent ? Color.green : failed ? Color.red : Color.secondary)
            .help("\(name): \(sent ? "sent" : failed ? "failed" : "waiting")")
            .accessibilityLabel(Text("\(name) \(sent ? "sent" : failed ? "failed" : "waiting")"))
    }
}

/// A scrobble in a list: artwork, title, artist, time and send state.
public struct ScrobbleRowView: View {
    let record: ScrobbleRecord
    let artworkSize: CGFloat

    public init(record: ScrobbleRecord, artworkSize: CGFloat = 36) {
        self.record = record
        self.artworkSize = artworkSize
    }

    public var body: some View {
        HStack(spacing: 10) {
            ArtworkView(releaseMBID: record.releaseMBID, size: artworkSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.track).font(.callout.weight(.medium)).lineLimit(1)
                Text(record.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let error = record.lastError, !record.isFullySent {
                    Text(error).font(.caption2).foregroundStyle(record.permanentlyFailed ? .red : .orange).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(record.listenedAt, format: .relative(presentation: .named))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                HStack(spacing: 3) {
                    ServiceBadge(name: "Last.fm", sent: record.lastfmSent, failed: record.permanentlyFailed)
                    ServiceBadge(name: "ListenBrainz", sent: record.listenbrainzSent, failed: record.permanentlyFailed)
                }
                .font(.caption2)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// The weekly recap: how many plays, the most played artists as bars, the
/// top track, and (when the device can write one) a sentence from Apple's
/// on-device model.
public struct RecapView: View {
    let summary: ListeningSummary?
    let sentence: String?
    let sourceLabel: String
    let isLoading: Bool

    public init(summary: ListeningSummary?, sentence: String?, sourceLabel: String, isLoading: Bool) {
        self.summary = summary
        self.sentence = sentence
        self.sourceLabel = sourceLabel
        self.isLoading = isLoading
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("This Week").font(.headline)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
            }
            if let summary {
                if summary.plays == 0 {
                    Text("Nothing scrobbled yet this week.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(summary.plays) \(summary.plays == 1 ? "play" : "plays")")
                        .font(.title2.weight(.bold))
                        .contentTransition(.numericText())
                    if let sentence {
                        Text(sentence)
                            .font(.callout)
                            .transition(.opacity)
                    }
                    artistBars(summary)
                    if let track = summary.topTracks.first {
                        Label {
                            Text("\(track.track) — \(track.artist) (\(track.listens))").lineLimit(1)
                        } icon: {
                            Image(systemName: "music.note")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } else if !isLoading {
                Text("Couldn't load this week's plays.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(sourceLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .animation(.smooth, value: summary)
        .animation(.smooth, value: sentence)
    }

    private func artistBars(_ summary: ListeningSummary) -> some View {
        let top = Array(summary.topArtists.prefix(3))
        let most = max(1, top.first?.listens ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(top.enumerated()), id: \.offset) { _, artist in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(artist.name).font(.caption.weight(.medium)).lineLimit(1)
                        Spacer()
                        Text("\(artist.listens)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    GeometryReader { proxy in
                        Capsule()
                            .fill(.tint.opacity(0.75))
                            .frame(width: max(6, proxy.size.width * CGFloat(artist.listens) / CGFloat(most)))
                    }
                    .frame(height: 5)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
