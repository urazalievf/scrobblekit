# ScrobbleKit

[![CI](https://github.com/urazalievf/scrobblekit/actions/workflows/ci.yml/badge.svg)](https://github.com/urazalievf/scrobblekit/actions/workflows/ci.yml)

A personal, open-source Apple Music scrobbler. Every play goes to both
[Last.fm](https://www.last.fm) and [ListenBrainz](https://listenbrainz.org).

- **ScrobbleKit for Mac**: a menu bar app that follows Music.app in real time.
- **ScrobbleKit for iPhone**: a companion app that catches what iOS lets it catch.
- **ScrobbleCore**: the shared Swift package (API clients, queue, matching, storage).
- **Listens widget**: a small HTML/CSS/JS embed that shows recent ListenBrainz listens.

> Screenshots: coming soon.

## What it can and can't capture

**Mac: every play in Music.app on that Mac.** Music posts a
`com.apple.Music.playerInfo` notification on each play, pause, stop and
track change. ScrobbleKit listens for it, with no polling. When the app starts while
something is already playing, it asks Music for the current track once
(you'll see an Automation prompt the first time).

**iPhone: roughly 85–95% of plays.** iOS doesn't let apps watch Apple Music
continuously, so ScrobbleKit combines three things:

1. **While the app is open**, plays are caught in real time from the system
   music player.
2. **In the background**, iOS runs ScrobbleKit's refresh task every so often
   (it asks for every 15 minutes; iOS decides). Each run reads Apple Music's
   Recently Played list and scrobbles what's new.
3. **A Shortcuts automation** (Time of Day → hourly → "Sync Scrobbles") fills
   the gaps.

What gets missed: Recently Played lists each song once, so playing the same
song twice between check-ins counts once. Songs without a play date in your
library get an estimated time, worked back from the songs played after them.
There are no silent-audio tricks or private APIs, so this is the ceiling.

## When a play counts

A track is scrobbled once it has played for half its length or 4 minutes,
whichever comes first. Tracks of 30 seconds or less never count; podcasts are
skipped. Scrubbing to the end counts (Last.fm filters what it doesn't want).
Timestamps are the track's start time in Unix UTC seconds.

## Both services, tracked separately

Each play is stored once with a separate sent flag per service. If Last.fm
accepts it and ListenBrainz is down, only ListenBrainz is retried. Retries
back off: 30 s, 2 min, 10 min, 1 h, 6 h, then daily, and give up after 10
attempts (you can retry by hand). ListenBrainz's rate-limit wait is honoured.
If Last.fm suspends the app's API key (error 26), Last.fm sending stops and
the app says so prominently. ListenBrainz keeps working.

## MusicBrainz matching

Before a play is sent to ListenBrainz, ScrobbleKit looks up the MusicBrainz
recording. It is deliberately strict, because a wrong recording ID is worse
than none (ListenBrainz trusts a submitted ID over its own matching):

- It fetches 25 candidates for `artist + title`, using the album to rank them.
- It accepts only an exact title and artist match (ignoring case, accents
  and curly quotes) whose length is within 10 seconds of the track.
- Otherwise it sends no ID and lets ListenBrainz match the listen itself.

Results are cached: matches forever, misses for 7 days. Requests carry an
identifying User-Agent and are limited to one per second.

## Duplicates and other devices

Plays are deduplicated by artist, title and the **minute** they started. If
the iPhone sees a play through both the foreground monitor and Recently
Played, or iCloud brings back old plays, they merge into one record.

The tradeoff: two reports of the same play whose start times fall on either
side of a minute boundary are kept as two plays. Matching on a wider window
would merge genuine back-to-back repeats instead. ScrobbleKit picks the
mistake that's easier to spot and delete (swipe a row to remove it).

**Ignore other devices** (on by default):

- **Mac:** always on. Music only reports the Mac's own playback.
- **iPhone:** Recently Played covers every device on your Apple ID and doesn't
  say which device played what. With this on, a play that already appears in
  your ListenBrainz history near the same time (for example because the Mac
  app sent it) is skipped. This needs ListenBrainz connected. Plays from
  devices that don't scrobble, like a HomePod, are still picked up.

## Privacy and credentials

- The Last.fm session key and ListenBrainz token are stored in the Keychain,
  never in files.
- The Last.fm API key and shared secret come from a git-ignored `.env` file
  and are copied into the app at build time (like every Last.fm client app,
  the built app contains them).
- ScrobbleKit talks only to Last.fm, ListenBrainz, MusicBrainz and the Cover
  Art Archive.

## Building

Requirements: macOS 14+ and iOS 17+ to run; Xcode 16 or later to build (the
project uses Xcode 16's folder-synchronized groups); an Apple Developer
account.

1. Clone the repository.
2. `cp .env.example .env`, then fill in `LASTFM_API_KEY` and
   `LASTFM_SHARED_SECRET` from
   [your Last.fm API account](https://www.last.fm/api/account/create).
3. Open `Apps/ScrobbleKit.xcodeproj`. The targets are signed with the
   author's team; change **Signing & Capabilities → Team** to yours, and the
   bundle identifiers if needed.
4. iPhone only: in the Apple Developer portal, enable the **MusicKit** app
   service for the iOS app's identifier.
5. Run **ScrobbleKitMac** or **ScrobbleKitiOS**.

Then, on Mac: click the waveform in the menu bar → Preferences → log in to
Last.fm (your browser opens and returns to the app) and paste your
ListenBrainz token from [listenbrainz.org/settings](https://listenbrainz.org/settings/).
On iPhone: finish onboarding, connect both services in Settings, and set up
the hourly "Sync Scrobbles" automation in Shortcuts.

### Tests

```sh
swift test
```

The shared package is tested headless: signatures, API clients against
canned responses, the playback rules, Recently Played diffing, dedup, retry
and the queue. The apps are build-checked in CI.

## Listens widget

`Web/listens-widget/` is a framework-free embed. Copy `listens.css` and
`listens.js` next to your page and add:

```html
<section class="lb-widget" data-user="your-listenbrainz-name"></section>
<link rel="stylesheet" href="listens.css">
<script src="listens.js" defer></script>
```

It shows what's playing now and the last 10 listens with cover art, caches
results for 60 seconds, shows the last saved listens if ListenBrainz is
unreachable, and refreshes every 60 seconds while the tab is visible.

## Not included

Microphone listening, Spotify / YouTube Music / Tidal, social features,
multiple users, Apple Watch and iPad layouts.

## License

MIT. See [LICENSE](LICENSE).

**No warranty, no support.** This is a personal project, shared as is. Issues
and pull requests may go unanswered.
