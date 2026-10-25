# Reel

A media player for iPhone and iPad that plays nearly any video file (MKV included), streams from
network shares or local storage, sorts the library into TV and Films, and fetches artwork from TMDb.

- **Plan:** [`PLAN.md`](PLAN.md) — scope, features, UI flow, solution design, decisions.
- **Prototype:** [`prototype/index.html`](prototype/index.html) — clickable UI mock-up (open in any browser).
- **Code:** `Reel/` (SwiftUI app) and `Packages/ReelKit/` (six Swift modules).

"Reel" is a placeholder name.

## Requirements

- Xcode 15.3 or later, iOS 17 deployment target.
- A paid Apple Developer account (needed for iCloud sync and TestFlight).
- A free TMDb v3 API key for metadata and artwork (themoviedb.org → Settings → API). The app works without one but shows plain file names.

## Build

The Xcode project is generated from `project.yml` so it never conflicts in git. VLCKit is not
on Swift Package Manager, so VideoLAN's official VLCKit 4 binary is fetched once per checkout.

```sh
brew install xcodegen
Scripts/fetch-vlckit.sh    # ~520 MB download → Packages/ReelKit/Vendor/VLCKit.xcframework (iOS slices only, ~140 MB, gitignored)
xcodegen generate          # creates Reel.xcodeproj
open Reel.xcodeproj
```

`project.yml` already carries the team (`834D8P4J32`, automatic signing) and bundle ID
`uk.co.ketelle.reel`. Xcode resolves AMSMB2 and KeychainAccess on first open.

**iCloud needs one interactive step.** The App ID has to be registered with the iCloud capability and
the `iCloud.uk.co.ketelle.reel` container created. Xcode does this itself the first time you build with
an Apple ID signed in (Xcode → Settings → Accounts). Until then signing fails with "No Accounts" and
"profile doesn't include the iCloud capability". For a device build without iCloud in the meantime run
`Scripts/build-device.sh`, which signs with `Reel/Reel-NoiCloud.entitlements` and installs on the phone.
Xcode rewrites `Reel/Reel.entitlements` to an empty `<dict/>` on every such build; the script restores it,
otherwise `git checkout -- Reel/Reel.entitlements`.

**No XcodeGen?** Create an empty iOS App project named `Reel` in Xcode, delete its generated
`ContentView.swift`/`ReelApp.swift`, drag the `Reel/` folder in, add the local package at
`Packages/ReelKit` (File → Add Package Dependencies → Add Local) and link all six products, then
copy the `info.properties` and entitlements from `project.yml`/`Reel/Reel.entitlements` into the target.

### VLCKit

`Packages/ReelKit/Package.swift` declares `VLCKit` as a local binary target at
`Packages/ReelKit/Vendor/VLCKit.xcframework`, only when that folder exists. Without it the pure
modules still build and test (Linux CI, fresh checkout); `VLCPlaybackEngine` is behind
`#if canImport(VLCKit)`. The fetch script pins VLCKit **4.0.0a19** (a prerelease: the first VLCKit with
Picture in Picture) by sha256 from `download.videolan.org/pub/cocoapods/unstable/`, keeps only the iOS
device and simulator slices and strips the dSYMs. To upgrade, change `VERSION` and `SHA256` in the
script and delete the `Vendor` folder. `VLCKIT_ARCHIVE=/path/to/VLCKit-4.…tar.xz` reuses a download.

The licence route is LGPL: VLCKit 4 is a **dynamic** framework (verified with `file`), embedded
by Xcode, and credited in Settings → About → Licences. Do not switch to a static build.

## Run

1. Launch on a device (the simulator can't reach SMB shares on most networks, and has no hardware decoder).
2. First run: paste the TMDb key (optional), then **Get started** → add a source.
   - **Local:** pick a folder in Files (USB drives and iCloud Drive appear there).
   - **Network:** choose a discovered host or enter one manually → Test Connection → tick folders and tag them TV / Films / Mixed → Start scanning.
3. The scan runs in the background; a banner on Home shows progress. Unmatched files land in **Needs Review** (wrench icon on Home).

## Tests

`Packages/ReelKit/Tests` holds pure-logic tests that need no device:

```sh
cd Packages/ReelKit && swift test --filter 'MediaCoreTests|MetadataTests'
```

or run the `Reel` scheme's tests in Xcode. `FilenameParserTests` is the table of real-world names
that the classifier must get right; add a row whenever a file is misfiled.

## Status

What is built (phase 1–2 of PLAN.md §7). Compiles for iOS with Xcode 26.6, all 27 unit tests pass, and a
signed Debug build installs on a device. The device smoke test (HANDOVER.md §4) has not been run yet.

| Area | State |
|---|---|
| Filename parser, classifier, item keys | Done, unit tested |
| TMDb client, cache, rate limiter, match scoring | Done, unit tested |
| Sources: Local (bookmarks), WebDAV, SMB (AMSMB2) | Done |
| Discovery (Bonjour SMB/WebDAV) | Done |
| Scanner (incremental), matcher, SwiftData schema | Done |
| iCloud sync (CKSyncEngine): sources, scanned library, watch state, favourites, overrides, collections; passwords via iCloud Keychain | Done |
| VLCKit engine: tracks, subtitles, delays, chapters, rate | Done |
| Picture in Picture (VLCKit 4; auto on swipe-home, button in player) | Done |
| Player UI: gestures, scrubber, sheets, Up Next, error card, lock | Done |
| Home, TV, Films (genre/year/sort filters), detail pages, Search, Favourites, Collections, History | Done |
| Sources, Add Source (discovered/manual/local), folder tags, file browser | Done |
| Needs Review, Fix Match, Settings, Licences, Attribution | Done |
| FTP/SFTP/NFS/DLNA browsing | Not yet (greyed out in Add Source) |
| Anime matching (AniDB titles + Anime-Lists → TMDb), TheTVDB fallback (optional key) | Done |
| Picture in Picture (VLCKit 4) | Done |
| "Open in Reel" from other apps + `reel://play?url=` scheme | Done |
| OpenSubtitles search/download (own key + account), fanart.tv logos (own key) | Done (24 Oct) |
| Offline downloads (Downloads tab), Wake-on-LAN for a sleeping NAS, film collections, diagnostics log | Done (24 Oct) |
| Scrub thumbnails, subtitle style, trailers, person pages, universes, smart collections, artwork editing, Siri shortcuts | Done (24 Oct) |
| Home Screen widgets | Not yet (needs an App Group in the provisioning profile) |
| Background scan continuation (background task + BGProcessingTask) | Done |

## First build

The first compile (Xcode 26.6, 24 Oct 2026) needed only small fixes, listed in `HANDOVER.md` §3.1.
The device build is warning-free.

## Shipped API keys

Reel ships with its own TMDB, fanart.tv and OpenSubtitles keys so a fresh install gets artwork
without the user registering anywhere. They live in `Secrets.xcconfig` at the repo root, which is
git-ignored; copy `Secrets.example.xcconfig` to it and fill in the values. `Scripts/ensure-secrets.sh`
(run by the build script) creates an empty one so a clone builds without keys. The values reach the
app through Info.plist (`REEL_TMDB_KEY` and friends) and a key typed into Settings overrides the
built-in one. Never commit the real file.
