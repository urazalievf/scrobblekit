# ScrobbleKit privacy policy

Last updated: November 20, 2026

ScrobbleKit (the iPhone app, the Mac app and `scrobblekit-mcp`) is made by
Feruz Urazaliev. ScrobbleKit runs no servers and collects nothing for its
developer. There are no accounts, no analytics, no ads and no tracking.

## What ScrobbleKit reads

- **What you play in Apple Music**, with your permission:
  - on the Mac, from the Music app;
  - on iPhone, from the system music player while the app is open;
  - on both, from your Apple Music account's Recently Played, read through
    Apple's MusicKit. On the Mac this happens only when you turn on "Catch
    plays from my other devices".
- **Your ListenBrainz token and Last.fm login**, which you enter yourself.
  They're kept in your device's Keychain.

## What ScrobbleKit stores

The plays it records (artist, track, album, when you played it, its length and
how long you played it) are stored on your device, so they can be sent and
retried. Deleting the app deletes them.

## Where it sends things

ScrobbleKit talks only to these services, and only for these purposes:

| Service | What it gets | Why |
|---|---|---|
| ListenBrainz (MetaBrainz Foundation) | Your plays, with your token | To record your listens, if you connected ListenBrainz |
| Last.fm | Your plays, with your session | To scrobble, if you connected Last.fm |
| MusicBrainz | Artist, title and album of a track | To find the track's MusicBrainz recording |
| Cover Art Archive | A MusicBrainz release ID | To show album art |
| Apple Music | A request for your Recently Played | To find plays from your other devices |

What ListenBrainz and Last.fm do with your plays is covered by their own
privacy policies. Listening history on ListenBrainz is public.

## Siri, the weekly recap and AI assistants

- **Siri and Shortcuts answers** are worked out on your device from your
  scrobbles, or fetched from your ListenBrainz history.
- **The recap's one-sentence summary** is written on your device by Apple's
  on-device model. Only the week's counts go into it, and nothing leaves the
  device.
- **`scrobblekit-mcp`** runs on your Mac and reads your public ListenBrainz
  history for the AI app you connect it to. It sends nothing anywhere else.

## TestFlight

If you test ScrobbleKit through TestFlight, Apple shares crash reports with
the developer, and any feedback, screenshots and usage data you choose to
send through TestFlight. Apple's TestFlight terms cover that data.

## Your choices

- Disconnect ListenBrainz or Last.fm in the app's settings at any time.
- Turn off Apple Music access in your device's Settings.
- Delete stored plays by swiping them away, or by deleting the app.

## Contact

Questions about this policy: open an issue at
https://github.com/urazalievf/scrobblekit/issues.
