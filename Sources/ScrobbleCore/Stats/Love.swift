import Foundation

/// "Love this track" for Siri and Shortcuts: Last.fm's `track.love`, and
/// ListenBrainz's recording feedback, which needs the MusicBrainz recording.
public enum Love {
    /// Sends to every connected service that can take it and returns one
    /// sentence saying what happened.
    public static func send(
        _ target: Scrobble, recordingMBID: String?,
        lastfm: LastFMClient?, lastfmSession: String?,
        listenbrainz: ListenBrainzClient, listenbrainzToken: String?
    ) async -> String {
        var loved: [String] = []
        var problems: [String] = []
        if let lastfm, let lastfmSession {
            do {
                try await lastfm.love(artist: target.artist, track: target.track, sessionKey: lastfmSession)
                loved.append("Last.fm")
            } catch {
                problems.append("Last.fm didn't accept it")
            }
        }
        if let listenbrainzToken {
            if let recordingMBID {
                do {
                    try await listenbrainz.love(recordingMBID: recordingMBID, token: listenbrainzToken)
                    loved.append("ListenBrainz")
                } catch {
                    problems.append("ListenBrainz didn't accept it")
                }
            } else {
                problems.append("ListenBrainz needs a MusicBrainz match and this track has none")
            }
        }
        guard !loved.isEmpty || !problems.isEmpty else { return "Connect ListenBrainz or Last.fm first." }
        var sentence = loved.isEmpty
            ? "Couldn't love \(target.track) by \(target.artist)."
            : "Loved \(target.track) by \(target.artist) on \(ListeningSummary.list(loved))."
        if !problems.isEmpty {
            let text = ListeningSummary.list(problems)
            sentence += " " + text.prefix(1).uppercased() + text.dropFirst() + "."
        }
        return sentence
    }
}
