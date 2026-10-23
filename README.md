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

The Xcode project is generated from `project.yml` so it never conflicts in git.

```sh
brew install xcodegen
xcodegen generate          # creates Reel.xcodeproj
open Reel.xcodeproj
```

Then in Xcode: select the **Reel** target → Signing & Capabilities → pick your Team. Xcode will
resolve the Swift packages (VLCKit, AMSMB2, KeychainAccess) on first open.

**No XcodeGen?** Create an empty iOS App project named `Reel` in Xcode, delete its generated
`ContentView.swift`/`ReelApp.swift`, drag the `Reel/` folder in, add the local package at
`Packages/ReelKit` (File → Add Package Dependencies → Add Local) and link all six products, then
copy the `info.properties` and entitlements from `project.yml`/`Reel/Reel.entitlements` into the target.

### If VLCKit fails to resolve

`Packages/ReelKit/Package.swift` points at the official VLCKit Swift package. VideoLAN has moved the
package URL and product name before. If resolution fails:

1. Check the current URL in the VLCKit README at <https://code.videolan.org/videolan/VLCKit>.
2. Update the `.package(url:)` line and the `.product(name:)` in the `Playback` target.
3. The wrapper imports `VLCKit` or `MobileVLCKit`, whichever is available, so either 3.x product works.

The licence route is LGPL: VLCKit is linked dynamically as an xcframework and credited in Settings → About → Licences. Do not switch to a static build.

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

What is built (phase 1–2 of PLAN.md §7), untested on a device until the first Xcode build:

| Area | State |
|---|---|
| Filename parser, classifier, item keys | Done, unit tested |
| TMDb client, cache, rate limiter, match scoring | Done, unit tested |
| Sources: Local (bookmarks), WebDAV, SMB (AMSMB2) | Done |
| Discovery (Bonjour SMB/WebDAV) | Done |
| Scanner (incremental), matcher, SwiftData schema | Done |
| iCloud sync (CKSyncEngine) for watch state, favourites, overrides, collections | Done |
| VLCKit engine: tracks, subtitles, delays, chapters, rate | Done |
| Player UI: gestures, scrubber, sheets, Up Next, error card, lock | Done |
| Home, TV, Films (genre/year/sort filters), detail pages, Search, Favourites, Collections, History | Done |
| Sources, Add Source (discovered/manual/local), folder tags, file browser | Done |
| Needs Review, Fix Match, Settings, Licences, Attribution | Done |
| FTP/SFTP/NFS/DLNA browsing | Not yet (greyed out in Add Source) |
| OpenSubtitles search, TheTVDB, Fanart.tv | Not yet |
| Picture in Picture, scrub thumbnails | Not yet (phase 4) |
| Background scan scheduling (BGAppRefreshTask) | Not yet |

## Known first-build risks

This code was written without access to Xcode, so expect a handful of compile errors on the first
build. The most likely spots are listed in `PLAN.md` §12. Fix forward; the structure is sound.
