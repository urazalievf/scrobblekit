# ScrobbleKit

[![CI](https://github.com/urazalievf/scrobblekit/actions/workflows/ci.yml/badge.svg)](https://github.com/urazalievf/scrobblekit/actions/workflows/ci.yml)

A personal, open-source Apple Music scrobbler. Every play goes to
[ListenBrainz](https://listenbrainz.org), and to [Last.fm](https://www.last.fm)
if you use it.

- **ScrobbleKit for Mac**: a menu bar app that follows Music.app in real time
  and, if you turn it on, catches the plays from your iPhone, iPad and CarPlay
  too.
- **ScrobbleKit for iPhone**: a companion app that catches what iOS lets it catch.
- **ScrobbleCore**: the shared Swift package (API clients, queue, matching, storage).
- **scrobblekit-mcp**: your ListenBrainz listening history for Claude and other
  AI assistants.
- **Listens widget**: a small HTML/CSS/JS embed that shows recent ListenBrainz listens.

> Screenshots: coming soon.

## Install

**Mac:** download `ScrobbleKit-mac-<version>.zip` from the
[latest release](https://github.com/urazalievf/scrobblekit/releases/latest),
unzip it and move **ScrobbleKit** to Applications. It's signed and notarized
by Apple, and needs macOS 14 or later. The download sends to ListenBrainz;
Last.fm needs a build with a Last.fm key (see below).

**iPhone:** a TestFlight beta is on the way. Until then, build it yourself
(see [Building](#building)).

## Last.fm from 1 December 2026

From 1 December 2026, [Last.fm only accepts an API key whose owner has Last.fm
Pro](https://support.last.fm/t/api-keys-will-require-pro-from-1st-december/121030).
The rule follows the key, not the listener: people using an app someone else
built don't need Pro, but whoever owns the key does.

What that means here:

- **ListenBrainz is the default.** It's free, needs only the token from your
  ListenBrainz settings, and ScrobbleKit works fully with ListenBrainz alone.
- **Building ScrobbleKit yourself:** the Last.fm key in your `.env` is yours,
  so Last.fm scrobbling needs Pro on the account that owns it. Without Pro,
  leave Last.fm out.
- **If Last.fm refuses the key** (error 10, invalid key, or 26, suspended),
  ScrobbleKit stops sending to Last.fm, says so in the menu bar and in
  Settings, and keeps sending to ListenBrainz. Plays are kept. Once the key
  works again, **Turn Last.fm Back On** sends what was waiting (Last.fm takes
  plays up to about 14 days old).

## What it can and can't capture

**Mac: every play in Music.app on that Mac.** Music posts a
`com.apple.Music.playerInfo` notification on each play, pause, stop and
track change. ScrobbleKit listens for it, with no polling. When the app starts while
something is already playing, it asks Music for the current track once
(you'll see an Automation prompt the first time).

**Mac, with "Catch plays from my other devices": your other devices too.**
Every 3 minutes while the Mac is awake, ScrobbleKit reads your Apple Music
account's Recently Played (the same list the iPhone app reads), which covers
the iPhone, iPad and CarPlay, and HomePod when it reports there. It scrobbles
what no device has sent yet. Nothing has to run on the iPhone. Times are
estimated to within a few minutes, and a song replayed between two checks
counts once. Turn it on in Preferences → General; it asks for Apple Music
access the first time.

Preferences also shows a measured figure: of the plays the Mac caught exactly
in the last 7 days, how many Apple's Recently Played also listed. That's the
honest ceiling for any Recently Played–based capture, including the iPhone
app's.

**iPhone: roughly 85–95% of plays.** iOS doesn't let apps watch Apple Music
continuously, so ScrobbleKit combines three things:

1. **While the app is open**, plays are caught in real time from the system
   music player.
2. **In the background**, iOS runs ScrobbleKit's refresh task every so often
   (it asks for every 15 minutes; iOS decides). Each run reads the last 120
   entries of Apple Music's Recently Played and scrobbles what's new.
3. **Shortcuts automations** fill the gaps. Add personal automations that run
   **Sync Scrobbles** without asking: when your headphones disconnect
   (Bluetooth), when CarPlay disconnects, and once late at night (Time of
   Day), each with **Ask Before Running** off. A listening session ends, and
   its plays go out.

Recently Played is read from the Apple Music API with library songs included.
Since August 2026 Apple leaves out plays started from your library or your
own playlists unless the request asks for them, which MusicKit's built-in
request can't do.

What gets missed: Recently Played lists each song once, so playing the same
song twice between check-ins counts once. Songs without a play date in your
library get an estimated time, worked back from the songs played after them.
There are no silent-audio tricks or private APIs, so this is the ceiling.

## When a play counts

A track is scrobbled once it has played for half its length or 4 minutes,
whichever comes first. Tracks of 30 seconds or less never count; podcasts are
skipped. Scrubbing to the end counts (Last.fm filters what it doesn't want).
Timestamps are the track's start time in Unix UTC seconds.

Last.fm gets the play as soon as it counts. For a play the Mac or the open
iPhone app watched live, ListenBrainz gets it when the track ends, with how
long you actually listened (`duration_played`) and the track's length
(`duration_ms`). If the track never ends as far as the app can tell (it quit,
or iOS suspended it), ListenBrainz gets the play a couple of minutes after
the track would have ended, without a played time.

## Both services, tracked separately

Each play is stored once with a separate sent flag per service. If Last.fm
accepts it and ListenBrainz is down, only ListenBrainz is retried. Retries
back off: 30 s, 2 min, 10 min, 1 h, 6 h, then daily, and give up after 10
attempts (you can retry by hand). ListenBrainz's rate-limit wait is honoured.
If Last.fm stops accepting the app's API key (error 10 or 26), Last.fm
sending stops and the app says so prominently. ListenBrainz keeps working.

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

**Plays another device already sent.** Recently Played covers every device on
your Apple ID and doesn't say which device played what. Before storing a
play found there, ScrobbleKit checks it against the plays this device caught
live and, with ListenBrainz connected, your ListenBrainz history:

- A play with a date in your library matches the same track within 15
  minutes of that date.
- A play without a date only has an estimated time. All that's certain is
  that Apple listed it after the previous check, and Apple can list plays
  hours late, so it matches the same track anywhere from 2 hours before the
  previous check until now.
- Listens this device sent from earlier Recently Played checks don't count
  as "another device", so a song you replay later isn't mistaken for its own
  earlier play.

The cost: replaying a song on a device that doesn't scrobble (a HomePod)
within that span of scrobbling it elsewhere counts once. On iPhone the
ListenBrainz part of the check is the **Ignore other devices** switch (on by
default); on the Mac it's always on with "Catch plays from my other devices".

## Ask Siri, and the weekly recap

Both apps add these to Siri, Spotlight and Shortcuts:

- "What did I listen to in ScrobbleKit" (any day: today if you don't say)
- "My top artists in ScrobbleKit" / "Top artists this month in ScrobbleKit"
- "My top tracks in ScrobbleKit"
- "Love this song in ScrobbleKit": loves what's playing on Last.fm, and on
  ListenBrainz when the track has a MusicBrainz match
- "Sync scrobbles in ScrobbleKit"

Answers come from ListenBrainz when it's connected (every device that
scrobbles there) and from the device's own scrobbles otherwise. Long periods
use ListenBrainz's statistics, which update about once a day.

**This Week** (the iPhone home screen, and a Preferences tab on the Mac)
shows the week's plays, most played artists and top track. On devices with
Apple Intelligence, Apple's on-device model adds one sentence about the
week. Only the counts go into it, and nothing leaves the device.

## Listening history for AI assistants

`scrobblekit-mcp` is a small [MCP](https://modelcontextprotocol.io) server
that lets Claude Desktop, Claude Code and other MCP clients answer questions
about your listening from your public ListenBrainz history. It only reads.

| Tool | What it answers |
|---|---|
| `listening_summary` | "What did I listen to yesterday / this week?" |
| `top_artists`, `top_tracks` | Favourites this week, month, year or of all time |
| `recent_listens` | The exact plays between two times |
| `listen_count` | Every listen on the account |

Build it once:

```sh
swift build -c release --product scrobblekit-mcp
```

Then add it to your client with your ListenBrainz user name. Claude Code:

```sh
claude mcp add scrobblekit --env LISTENBRAINZ_USER=your-name -- "$PWD/.build/release/scrobblekit-mcp"
```

Claude Desktop (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "scrobblekit": {
      "command": "/path/to/scrobblekit/.build/release/scrobblekit-mcp",
      "env": { "LISTENBRAINZ_USER": "your-name" }
    }
  }
}
```

It runs on your Mac and talks only to ListenBrainz. Listening history there is
public, so it needs no token.

## Privacy and credentials

- The Last.fm session key and ListenBrainz token are stored in the Keychain,
  never in files.
- The Last.fm API key and shared secret come from a git-ignored `.env` file
  and are copied into the app at build time (like every Last.fm client app,
  the built app contains them).
- ScrobbleKit talks only to ListenBrainz, Last.fm, MusicBrainz, the Cover Art
  Archive and Apple Music (for Recently Played, through MusicKit).
- The weekly recap's sentence is written on the device; nothing is sent
  anywhere for it.

## Building

Requirements: macOS 14+ and iOS 17+ to run; Xcode 16 or later to build (the
project uses Xcode 16's folder-synchronized groups); an Apple Developer
account.

1. Clone the repository.
2. Optional, for Last.fm: `cp .env.example .env`, then fill in
   `LASTFM_API_KEY` and `LASTFM_SHARED_SECRET` from
   [your Last.fm API account](https://www.last.fm/api/account/create). From 1
   December 2026 that account needs Last.fm Pro (see above). Without a key,
   the apps work with ListenBrainz only.
3. Open `Apps/ScrobbleKit.xcodeproj`. The targets are signed with the
   author's team; change **Signing & Capabilities → Team** to yours, and the
   bundle identifiers if needed.
4. In the Apple Developer portal, enable the **MusicKit** app service for
   both apps' identifiers (the iPhone app reads Recently Played; the Mac app
   does when "Catch plays from my other devices" is on).
5. Run **ScrobbleKitMac** or **ScrobbleKitiOS**.

Then, on Mac: click the waveform in the menu bar → Preferences → paste your
ListenBrainz token from [listenbrainz.org/settings](https://listenbrainz.org/settings/)
(and log in to Last.fm if you use it: your browser opens and returns to the
app). Turn on **Catch plays from my other devices** if you want your iPhone's
plays caught from the Mac. On iPhone: finish onboarding, connect ListenBrainz
(and Last.fm) in Settings, and add the Sync Scrobbles automations in
Shortcuts.

### Releasing

`scripts/release-mac.sh` builds the Mac app for direct download: Developer ID
signing, Apple notarization, stapling and a zip. `scripts/release-ios.sh`
archives the iPhone app and uploads it to App Store Connect for TestFlight
(`DESTINATION=export` writes the `.ipa` instead). Both read an App Store
Connect API key from `ASC_KEY_PATH`, `ASC_KEY_ID` and `ASC_ISSUER_ID`; the
comments at the top of each script list the certificates and profiles they
expect.

### Tests

```sh
swift test
```

The shared package is tested headless: signatures, API clients against
canned responses, the playback rules, Recently Played reading and diffing,
dedup and the other-devices check, retry, the queue, statistics, and the MCP
server. The apps are build-checked in CI.

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

Microphone listening, Spotify / YouTube Music / Tidal (Spotify scrobbles to
Last.fm by itself, and [Web Scrobbler](https://webscrobbler.com) covers web
players), social features, multiple users, Apple Watch and iPad layouts.

## Sponsor

ScrobbleKit is free. If it's useful to you, you can back my work through
[GitHub Sponsors](https://github.com/sponsors/urazalievf) or
[Patreon](https://www.patreon.com/furazaliev).

## License

MIT. See [LICENSE](LICENSE).

**No warranty, no support.** This is a personal project, shared as is. Issues
and pull requests may go unanswered.
