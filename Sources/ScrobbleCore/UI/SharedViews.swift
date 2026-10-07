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
