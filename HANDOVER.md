# Reel — agent handover

You are picking up an iOS/iPadOS media player that has been fully planned, prototyped and written.
It was first authored in a Linux container with no Swift toolchain; on 24 Oct 2026 it was brought to
a **compiling, signed, device-installable** state on Paul's Mac (Xcode 26.6). The device smoke test
(§4) has not been run. Your first job is that smoke test, then continue the phase plan.
Everything you need is in this repo; this document is the map.

Read in this order: this file → `PLAN.md` §6, §10, §11, §12 → `BUILDING.md` → the code.

---

## 1. What this is

| | |
|---|---|
| Product | iPhone + iPad video player. Plays ~99% of files including MKV via VLCKit. Streams from SMB / WebDAV / local folders. Sorts into TV and Films with TMDb artwork. iCloud sync of watch state and favourites. Think Infuse. |
| Name | **Reel** (placeholder, change freely) |
| Owner | Paul (paul@ketelle.co.uk). Has a paid Apple Developer account. |
| Distribution | TestFlight (build 4 uploaded 31 Oct 2026); App Store listing filled in, not submitted. |
| Pricing | Free. No in-app purchases, no adverts. This keeps TMDb and friends on their non-commercial terms. |
| Licence route | **LGPL.** VLCKit linked dynamically as an xcframework, credited in Settings → About → Licences. Do not switch to a static VLC build. Do not add GPL-only modules. |
| Min iOS | 17.0 (needed for `CKSyncEngine`, SwiftData, modern SwiftUI navigation). |
| Branch | `claude/ios-media-player-planning-zikprx`. All work goes here. Commit often, push when green. |

Decisions already made by the owner (don't re-open without asking): VLCKit engine, LGPL, sideload-first, free-no-ads, iCloud sync for resume/watched/favourites, genre + year filters on TV and Films, decades (not individual years) for the year filter, single-select genre.

---

## 2. Repo layout

```
PLAN.md                 Product plan + solution design. §11 = architecture, §12 = first-build checklist.
README.md               App overview for the GitHub page; BUILDING.md has the build/run instructions.
HANDOVER.md             This file.
project.yml             XcodeGen spec → generates Reel.xcodeproj (gitignored).
Scripts/fetch-vlckit.sh Downloads VideoLAN's VLCKit 4.0.0a19 xcframework (iOS slices) into Packages/ReelKit/Vendor (gitignored).
Scripts/build-device.sh No-iCloud Debug build + install on the paired iPhone; restores Reel.entitlements afterwards (§3).
prototype/index.html    Clickable HTML prototype of every screen. Open in a browser. The app UI follows it.

Reel/                   SwiftUI app target
  App/                  ReelApp (entry, DI), AppSettings (UserDefaults-backed, @Published),
                        PlayerCoordinator (owns the engine, saves progress, Up Next), RootView (tabs vs sidebar)
  Views/Library/        HomeView, TVView (+FilmsView, FavouritesView, CollectionsView in TVView.swift),
                        DetailViews (HeroHeader, FilmDetailView, ShowDetailView, EpisodeRow, FlowLayout),
                        SearchView, NeedsReviewView (+FixMatchView)
  Views/Library/AudiobooksView.swift  Audiobooks list, BookRow/BookCover, BookProgress, AudiobookDetailView
  App/AudiobookTags.swift             Reads a book's embedded tags (title, author, cover) with VLCMedia.parse after a scan
  Views/Sources/        SourcesView (+SourceDetailView, TagSheet, FileBrowserView), AddSourceView,
                        FilesView (the Files tab: Downloads then every source as a plain folder tree; audio files play too)
  Views/Player/         PlayerView (PlayerView → PlayerContentView, Scrubber, TrackSheet, AirPlayButton, VolumeControl),
                        VLCVideoView (VLCDrawableView: the UIView VLC paints into + VLCPictureInPictureDrawable)
  Views/Settings/       SettingsView (+HiddenItemsView, HistoryView, LicencesView, AttributionView)
  Views/Components/     ArtworkImage (+Palette placeholder), PosterCard (+ItemContextMenu), FilterBar, ItemGrid (+ItemRow, ItemDestination, itemNavigation())
  Views/OnboardingView.swift
  Resources/Assets.xcassets   AccentColor (amber #F0A33A), empty AppIcon
  Reel.entitlements     CloudKit container + keychain group (the real one)
  Reel-NoiCloud.entitlements  Keychain group only; for device builds before the App ID has iCloud (§3.2)

Packages/ReelKit/       ONE Swift package, SIX modules (keeps Xcode happy, lets pure modules test on any platform)
  Sources/MediaCore     Models.swift, FilenameParser.swift, Classifier.swift, ItemKey.swift, Formatting.swift   — pure Swift
  Sources/Metadata      TMDbClient, TMDbModels, MetadataCache, RateLimiter, ArtworkURL, MatchScorer          — Foundation only
                        TVDBClient (v4, optional key), AniDBTitles (offline titles dump), AnimeLists (AniDB→TMDb
                        season/episode mapping), Gunzip (Apple zlib; AniDB dump is .xml.gz)
  Sources/MediaSources  MediaSource (protocol, SourceConfig, SourceFactory, withRetries), LocalSource,
                        WebDAVSource (+PropfindParser), SMBSource (#if canImport(AMSMB2)), FTPSource (own client:
                        FTPControl + FTPListing parsers), DLNASource (SSDP/description/DIDL parsers, ContentDirectory
                        Browse), StreamBridge, CredentialStore, SourceDiscovery, WakeOnLAN
  Sources/Playback      PlaybackState (protocol + PlaybackItem/Options), VLCPlaybackEngine, NowPlayingBridge,
                        HLSRemuxer + MP4Boxes (AirPlay copy), VLCDirectorySource (SFTP and NFS through VLC's
                        access modules; registered into SourceFactory at launch)
  Vendor/               VLCKit.xcframework + COPYING.txt (gitignored; binaryTarget declared only when present)
  Sources/Library       Models (SwiftData @Model classes + LibrarySchema), LibraryScanner (@ModelActor),
                        Matcher, LibraryStore (@MainActor façade), ImageLoader
  Sources/Sync          SyncEngine (CKSyncEngine delegate)
  Tests/MediaCoreTests  FilenameParserTests (13 cases), ClassifierTests (6)
  Tests/MetadataTests   TMDbClientTests (mock transport), MatchScorerTests
```

Module dependency graph: `MediaCore ← Metadata, MediaSources, Playback ← Library (Metadata, MediaSources) ← Sync`. The app links all six.

---

## 3. Build state (done 24 Oct 2026)

```sh
cd <repo>
brew install xcodegen            # if missing
Scripts/fetch-vlckit.sh          # VLCKit 4.0.0a19 → Packages/ReelKit/Vendor (gitignored, ~520 MB download, ~140 MB kept)
xcodegen generate                # → Reel.xcodeproj
open Reel.xcodeproj
```

`project.yml` carries Paul's team `834D8P4J32` and bundle ID `uk.co.ketelle.reel` (same prefix as
AiBrain / AudioStripper). Until the iCloud step in §3.2 is done, build a **no-iCloud dev build** from the
command line with `Scripts/build-device.sh`. It signs with `Reel/Reel-NoiCloud.entitlements` (keychain
group only), installs on the paired iPhone 17 Pro Max (`D83F0EFF-F81B-5BDF-ADC5-09FC08796658`) and then
restores `Reel/Reel.entitlements`, because **every xcodebuild run empties that file** while the App ID lacks
iCloud. This is what is on the phone now. Passing an empty `CODE_SIGN_ENTITLEMENTS=` is not enough; Xcode
still derives the iCloud requirement from the target's file.

### 3.1 What was fixed to get here

1. **VLCKit.** `code.videolan.org/videolan/VLCKit-SPM` does not exist (401). There is no official SwiftPM
   package for VLCKit 3.x. Replaced with VideoLAN's official **MobileVLCKit 3.7.3** binary, fetched by
   `Scripts/fetch-vlckit.sh` (sha256-pinned, mirrors VR Desktop's `fetch-vlckit.sh`) and declared as a local
   `binaryTarget` in `Package.swift` **only when the folder exists**, so the pure modules still build and
   test without it. It is a dynamic framework (checked with `file`), so the LGPL route is intact. The
   script strips `dSYMs` and the `DebugSymbolsPath` plist keys, otherwise Xcode rejects the xcframework.
2. **AMSMB2** bumped `3.x → 4.x` (3.4.0's libsmb2 target compiles stray Makefiles under Xcode 26). Its
   dependency is no longer iOS-conditional: `canImport(AMSMB2)` was true on macOS while the module wasn't
   linked, breaking `swift test`. The 3.x async API the code uses compiled unchanged against 4.0.3.
3. `Library/Models.swift` was missing `import MediaSources`.
4. `Playback/NowPlayingBridge.swift` now requires `canImport(UIKit)` (it uses `UIImage`/`AVAudioSession`),
   so macOS `swift test` builds.
5. `FilenameParser.isDecimalContext` only keeps the dot for single digits (`5.1`, `DD5.1`), not
   `S02E05.1080p` / `2022.2160p`. This was the cause of both parser test failures.
6. VLC delegate methods take `Notification` (non-optional) in 3.7.3 headers.
7. `extension String: Identifiable` replaced by `struct FolderPath` in `SourcesView.swift`.

The VLCKit 3.x API names, AMSMB2 async API, SwiftData `#Predicate`s, `CKSyncEngine` delegate and all
the Swift-isms the original author couldn't compile-check were **correct as written**. The device build
is warning-free.

### 3.2 Still needs Paul (interactive)

- **iCloud / CloudKit entitlements — DONE 24 Oct, afternoon.** Paul signed into Xcode and ran Reel on the
  iPad once; "iOS Team Provisioning Profile: uk.co.ketelle.reel" now exists with iCloud, keychain and
  `aps-environment` (CloudKit pushes), and includes both the iPhone and the iPad. `Scripts/build-device.sh`
  detects that profile and signs with the real `Reel/Reel.entitlements`. The paragraph below is history.
  **The entitlements file is generated**: XcodeGen rewrites `Reel/Reel.entitlements` from the
  `entitlements.properties` block in `project.yml` on every `xcodegen generate` (that, not Xcode, is what
  kept emptying it). Edit the keys in `project.yml`, never the plist.
- **(historical) iCloud / CloudKit entitlements.** No Apple ID is signed into Xcode on this Mac ("No Accounts"), so
  signing with `Reel/Reel.entitlements` fails: the wildcard team profile lacks the iCloud capability and
  the `iCloud.uk.co.ketelle.reel` container. Fix: Xcode → Settings → Accounts → sign in, open
  `Reel.xcodeproj`, build once for the device. Xcode registers the App ID + container and creates
  "iOS Team Provisioning Profile: uk.co.ketelle.reel", as it did for AiBrain. Beware: until then **every
  xcodebuild run rewrites `Reel/Reel.entitlements` to an empty `<dict/>`**; `Scripts/build-device.sh`
  restores it, otherwise `git checkout -- Reel/Reel.entitlements`. The no-iCloud build runs fine but
  iCloud sync is unavailable; everything else in §4 can be tested.
- **Launching on the phone** needs it unlocked (`devicectl` returned `Locked`). iPad: `DA605DF8-5248-5E92-A5E5-D4DF7E97DC87`.
- A TMDb API key for the scan/match steps.

### 3.3 Run the unit tests

```sh
cd Packages/ReelKit && swift test --filter 'MediaCoreTests|MetadataTests'
```
or Product → Test in Xcode. 27 tests, all passing as of this handover.

## 3.4 First device run (24 Oct 2026, Paul's NAS, 4,297 files)

Pulled the SwiftData store off the phone with `xcrun devicectl device copy from --domain-type appDataContainer
--domain-identifier uk.co.ketelle.reel --source "Library/Application Support"` and found:

- **Library empty despite a full scan.** The source was scanned before the TMDb key was entered, so the
  matcher never ran and nothing ever re-matched. Fixed: Home shows an "N files scanned but not matched"
  banner with *Match now*, Settings matches automatically when a 32-char key lands, and matcher errors now
  surface in `ScanProgress.lastError` instead of being swallowed.
- **261 Needs Review, almost all anime fansub names.** Parser now handles `[Group]Title_-_01_(tags)`,
  `(Hi10)_Title_-_01`, `Title - S03E11v2`, `Title Ep01`, `Episode 0 Title` under a `… Season 2` folder,
  `2nd Season` in a title, and `OVA/` folders as season 0. `/BDMV/` disc dumps are ignored. Review files
  with a guess are now tried by the matcher and accepted only on an unambiguous hit.
- **Fill mode shrank the video to a third.** `scaleFactor` is in pixels, not points. Fill now uses
  `videoCropGeometry` and is re-applied on layout.

## 3.5 VLCKit 4 and Picture in Picture (24 Oct 2026)

Paul wanted the video to keep playing in a floating window when he swipes to the home screen, like
YouTube. MobileVLCKit 3.x has no PiP API at all, so the engine moved to **VLCKit 4.0.0a19** (prerelease,
LGPL, dynamic) which ships its own `AVSampleBufferDisplayLayer` + `AVPictureInPictureController` bridge.

What changed:
- `Scripts/fetch-vlckit.sh` pulls `VLCKit-4.0.0a19-….tar.xz` from `download.videolan.org/pub/cocoapods/unstable`
  (sha256-pinned, ~520 MB), keeps only the `ios-arm64` and `ios-arm64_x86_64-simulator` slices, strips the
  dSYMs and rewrites `Info.plist` to match (~140 MB on disk). `VLCKIT_ARCHIVE=/path` reuses a download.
  `Package.swift` declares the `VLCKit` binary target (still only when the folder exists) and links AVKit.
- `VLCPlaybackEngine` is written against the VLCKit 4 API: `VLCMediaPlayer.Track` arrays
  (`audioTracks`/`textTracks`, `isSelectedExclusively`, `deselectAll…Tracks`) with the array index as the
  `MediaTrack.id`; `chapterDescriptions(ofTitle:)` returning `VLCMediaPlayer.ChapterDescription`;
  `setCropRatioWithNumerator(_:denominator:)` for Fill (0/0 resets); `mediaPlayerStateChanged(_ state:)`,
  `mediaPlayerLengthChanged`, `mediaPlayerTrackAdded`/`TrackSelected` delegate methods. VLC 4 has no
  `ended` state — a stream that runs out goes `stopping → stopped`; the engine reports `.ended` when that
  happens without its own `stop()` having been called. `VLCMedia(url:)` is now failable.
- PiP: `VLCDrawableView` (the UIView VLC paints into) conforms to `VLCPictureInPictureDrawable`. VLC's
  video output asks it for a `mediaController` (the engine's `pictureInPictureMediaController`, a small
  nonisolated object that drives `VLCMediaPlayer` directly because AVKit calls it off the main thread) and
  calls `pictureInPictureReady` with a `VLCPictureInPictureWindowControlling` once the first frame is up;
  the engine stores it weakly and publishes `canStartPictureInPicture` / `isPictureInPictureActive`.
  VLCKit's controller sets `canStartPictureInPictureAutomaticallyFromInline`, so iOS starts PiP by itself
  when the app is backgrounded mid-playback; `PlayerContentView` also calls `startPictureInPicture()` on
  `.background` as a belt-and-braces and `stopPictureInPicture()` on `.active`. There is a `pip.enter`
  button in the top controls and a row in the More sheet.
- No new Info.plist keys were needed beyond the existing `UIBackgroundModes: [audio]`.
- Paused, home gesture (or another app), back, play left the picture black (28 Oct 2026): iOS
  interrupts the AVSampleBufferDisplayLayer VLC paints through while the app is in the background and
  nothing enqueued shows until it is flushed, although VLC counts every frame as displayed. This VLCKit
  build only handles that for its OpenGL view, so `VLCPlaybackEngine.flushDisplayLayerIfNeeded()` finds
  the layer under the drawable and flushes it on `.active` (and on the first play after a paused
  return), logging its state each time. The lock screen never caused the interruption.

Verified:
- Device build (`Scripts/build-device.sh`) compiles warning-free in our code and installs on the iPhone.
- `swift test` — 37 tests pass.
- iPad Pro 11" simulator: the MKV plays through VLCKit 4's sample-buffer display; pressing Home starts PiP
  automatically (AVKit log: `alwaysStartsAutomaticallyWhenEnteringBackground YES`, `pictureInPictureActive YES`);
  playback keeps running in the background and the in-app view resumes at the right time when the app
  is foregrounded. The simulator's PiP window itself stays black (frames are enqueued at 30 fps but
  `displayed: 0, evicted: 180` — the simulator doesn't composite the sample-buffer layer into the PiP
  window) and draws no overlay controls, so play/pause/seek from the PiP window could only be checked
  by code inspection. **The iPhone simulator reports `isPictureInPictureSupported NO`**, so VLCKit never
  offers a controller there and the button doesn't appear; test on an iPad simulator or a device.

Still to confirm on the real phone (needs Paul): the PiP window shows video, its play/pause/±15 s
controls work (they go through `jumpWithOffset:completion:`), and Fit/Fill with the new crop-ratio API.

## 4. Device smoke test (your second task)

Needs: a TMDb v3 API key (free, themoviedb.org → Settings → API), a few MKVs, ideally a NAS with SMB.

1. Settings → paste TMDb key. Sources → + → Files picker → folder with 2–3 MKVs. Scan banner on Home → posters appear.
2. Sources → + → discovered NAS or manual SMB. Wrong password → red "Password rejected" in the form. Right password → folder list → tag TV/Films → Start scanning.
3. Play an MKV with 2+ audio tracks and a PGS subtitle. Switch both mid-play (no restart). Scrub. Double-tap skip. Lock. Close → reopen → Resume shows the right time.
4. iCloud on in Settings on two devices. Mark an episode watched on one; tick appears on the other.
5. Drop a file named `allotment_ep5_final_FINAL.mkv` in a scanned folder → appears in Needs Review (wrench on Home) → Fix match → pick result → poster updates.
6. Kill the NAS mid-playback → error card with Retry / other copy / Back, never a black screen.

Log what breaks as GitHub issues or in a `TESTING.md`; fix the blocking ones.

---

## 5. How things work (the parts you'll touch)

**Scan pipeline.** `LibraryStore.scan(record, tmdb:)` → `LibraryScanner` (background `@ModelActor`) connects via
`SourceFactory.make(config)`, BFS-walks tagged folders (or root), upserts `MediaFile` by `(relativePath, size, modified)`,
runs `Classifier.classify(path, folderTag)` → `episode / film / needsReview / ignore`, then `Matcher.match(file)`
searches TMDb, scores with `MatchScorer`, and upserts `MediaItem` (film / show / episode) keyed by `ItemKey`.
Progress is reported via a `@Sendable` closure to `LibraryStore.scanProgress`.

**Identity.** `ItemKey.film(tmdbID:)`, `.show(tmdbID:)`, `.episode(showTMDbID:season:episode:)`, and
`.unmatched(fileName:size:duration:)` (FNV-1a, stable across devices — never use Swift `Hasher` for this).
`WatchState`, `Favourite` and `MediaCollection` key on these; `ItemOverride` keys on the *file* key so a fix survives rescans.

**Playback.** `PlayerCoordinator.play(item, file:, fromStart:, settings:)` → `LibraryStore.playbackURL(for: file)`
(connects the source, builds `smb://user:pass@host/share/path` or an authenticated `https://` URL — never persist these)
→ `VLCPlaybackEngine.load(PlaybackItem, PlaybackOptions)`. Progress saved on pause, on exit, every 30 s, and at `.ended`
(marks watched at ≥95%). `PlayerView` is a thin wrapper around `PlayerContentView(engine:)` so the engine is an `@ObservedObject`.

**Sync.** `SyncEngine` keeps one private CloudKit zone `Library`. Rows with `pendingSync == true` are pushed;
`updatedAt` latest-wins on fetch; `Favourite.deletedAt` is a tombstone. Since 24 Oct (afternoon) the whole library
syncs, not just watch state: `Source` (minus password), `Item` and `File` records with deterministic names
(`SyncKeys`), so two devices scanning the same share converge; `serverRecordChanged` conflicts take the server copy.
`LibraryStore.syncHooks` (set in `ReelApp.init`) pushes after every write and mirrors deletions; the app fetches on
foreground and on CloudKit silent pushes (`AppDelegate`, `remote-notification` background mode). Relationships are
restored from `itemKeyHint` / `showKeyHint` once both records exist. Source passwords sync via iCloud Keychain
(`CredentialStore` marks items `synchronizable`). Files-app (local) sources never sync.

**Open in Reel.** `project.yml` declares `CFBundleDocumentTypes` for every video UTI (plus an imported
`org.matroska.mkv` type, since iOS has none) so DS file, Files, Safari and share sheets list Reel as a
viewer, and the `reel://` URL scheme (`reel://play?url=…&title=…`, or Infuse-style
`reel://x-callback-url/play?url=…`). `ReelApp.open(_:)` routes both to `PlayerCoordinator.playExternal`,
which plays the URL directly (security-scoped for files), keeps watch state keyed by the URL, and adds
nothing to the library.

**Settings.** `AppSettings` uses `@Published` + `didSet → UserDefaults`, not `@AppStorage`, because `@AppStorage`
doesn't notify an `ObservableObject`'s subscribers. Keep that pattern.

**Credentials.** `CredentialStore` (KeychainAccess, `afterFirstUnlock`), keyed by source UUID. Never in SwiftData, never in CloudKit, never logged.

---

## 6. Conventions

**Main-thread rules (learned the hard way on 24 Oct).** The store publishes on every scan step and every
sync, so anything a `body` reads from it runs again each time. Screens compute their rows into `@State`
and refresh through `.refreshFromLibrary { … }` (`Reel/Views/Components/LibraryRefresh.swift`, 500 ms
debounce); `LibraryStore.watchState(_:)` and `isFavourite(_:)` read in-memory caches that every write
and every sync apply invalidate; the player never observes the store, and its position-driven parts
observe `PlaybackClock`, not the engine, so the body with the gesture recognisers stays static. Images
are decoded in `ImageLoader`'s background task (`preparingForDisplay`). Keep it that way.

- Swift 5.10, SwiftUI, structured concurrency. Actors for sources and the scanner; `@MainActor` for stores and coordinators.
- Views read from `LibraryStore` via `@EnvironmentObject`; mutations go through `LibraryStore` methods (they set `pendingSync`).
- No new third-party dependencies without a licence check: permissive (MIT/Apache/BSD) only, and add it to `LicencesView` + PLAN §11.10.
- Match the surrounding comment density: a one-line `///` on public types, comments only where the *why* isn't obvious.
- Commit messages: imperative subject, short body. Push to the branch above. Don't open a PR unless asked.
- UI follows `prototype/index.html`. When you change a screen's behaviour, update the prototype's `QS` notes or the plan if the decision changes.
- Keep `PLAN.md` truthful: when a "Not yet" row in BUILDING.md's status table ships, flip it.

---

## 7. Open items, in phase order (PLAN.md §7)

Phase 2 remainder
- [x] Automatic push after writes + fetch on foreground/push (24 Oct). Library-wide sync (sources, items, files) too.
- [x] Background scanning (24 Oct): `LibraryStore.scan` holds a `beginBackgroundTask` assertion so a scan
      survives leaving the app for a few minutes, and `Reel/App/BackgroundScans.swift` schedules a
      `BGProcessingTask` (`uk.co.ketelle.reel.scan`) on every background transition: 60 s later if work is
      pending, else daily. It respects `scanOnCellular` via `NWPathMonitor.isExpensive`. iOS decides when it
      actually runs (usually charging + idle); to force it in the debugger pause the app and run
      `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"uk.co.ketelle.reel.scan"]`.
- [ ] Probe duration/codec/audio/subtitle summaries for `MediaFile` after first play (VLC `media.tracksInformation`) so Film detail's "File" section shows real codecs.
- [ ] Scan: mark files not seen for N scans as missing rather than keeping them forever.

Reliability (24 Oct, evening)
- [x] Diagnostics log: `Diagnostics.log(category, message)` (MediaCore) → Documents/Diagnostics/reel.log,
      Settings → About → Diagnostics (share/clear). Read this first for any "it just spun" report.
- [x] Player watchdogs (`VLCPlaybackEngine`): open (20 s without a tick), mid-stream stall (15 s without
      output pictures/audio buffers; VLC's clock keeps ticking on a dead socket so ticks are no guide),
      foreground check after PiP/background, and `reconnect(at:)` with a two-strike limit before the
      error card. Verified in the simulator against a black-hole IP and a SIGSTOPped local HTTP server.
- [x] Sync errors name the CKError code (`SyncEngine.describe`); Home shows "Synced x ago" or the problem.
- [x] Wake-on-LAN: `SourceConfig.macAddress` (synced), `WakeOnLAN.wake`, wake-and-wait in `playbackURL`.

Late 24 Oct (second batch)
- [x] Scans remove files a successful listing no longer shows; titles left empty are retired
      (`pendingDeletion`, purged at next launch) — `LibraryScanner`.
- [x] Player resilience: `VLCPlaybackEngine.rebuildPlayer` swaps in a fresh VLCMediaPlayer when the
      previous input is still stopping at load or an open times out (one automatic retry). Root cause of
      the iPad "hung then server error" report: the SMB pre-flight connected in 0.3 s, VLC was wedged.
- [x] Artwork: Edit artwork… on film/show/collection/universe/series cards (`ArtworkPickerView`):
      TMDb images, fanart.tv, TheTVDB (shows), collection posters, collages. Overrides on `MediaItem`
      (`posterOverrideURL`…), `MediaCollection.artworkURL/collageURLs`, `GroupArtwork` rows — all synced.
- [x] Universes (`Universes` in MediaCore, curated studio/keyword lists), film series, smart collections
      (`SmartCollectionStore`, per device), person pages, More like this, trailers, cast photos.
- [x] Scrub thumbnails (`ScrubThumbnails`, VLCMediaThumbnailer, Caches/scrub), subtitle style, codec
      probe on first play (`VLCPlaybackEngine.onProbe` → `LibraryStore.recordProbe`).
- [x] Native AVPlayer path for AirPlay with MP4/M4V/MOV over HTTP or downloads (`NativePlayerView`).
- [x] Siri shortcuts (`ReelIntents.swift`), keyboard shortcuts, VoiceOver labels, PrivacyInfo.xcprivacy.
- [ ] Widgets: need an App Group entitlement in the provisioning profile (Developer portal), not doable
      from the build script; `ReelRoutes.writeShowsSnapshot` already keeps a shared-ready snapshot.
- [ ] Group artwork and smart collections are the only per-device state left (smart rules).

Phase 3
- [x] OpenSubtitles (24 Oct): `OpenSubtitlesClient` (Metadata), `SubtitleSearchView` from the Subtitles
      sheet, files kept in Documents/Subtitles/<item>/ and re-added on play. Key + account in Settings.
      `TrackMemory` remembers the audio/subtitle choice per show.
- [x] Offline downloads (24 Oct): `DownloadManager` (app), `MediaSource.download(_:to:progress:)` on
      every source type, Downloads tab, player prefers the local copy. Sources moved to Settings → Library.
- [x] Film collections (24 Oct): `MediaItem.collectionID/Name` from TMDb `belongs_to_collection`;
      film page lists library films in the collection and names the missing ones.
- [x] Needs Review groups by folder with apply-to-all (`resolveReview(_ files:)`, `ignoreFiles`).
- [x] Second opinions (29 Oct): `Metadata/SecondOpinion.swift` has keyless `WikidataClient` (films and
      shows, entities carry TMDb ids P4947/P4983, release P577/P580), `TVmazeClient` (shows, IMDb/TheTVDB
      ids mapped through TMDb `/find`) and `KitsuClient` (anime, AniDB mapping). The matcher consults them
      only for weak results: an autoLow pick that the second source also names becomes autoHigh; a blank
      TMDb search is matched when the second source has exactly this title and year; otherwise the second
      source's pick lands on the file as `suggestedTMDbID`/`suggestionSource` and Needs Review shows it
      first, labelled "<source> agrees". Kitsu also breaks ties when two AniDB entries share a name.
      `SecondOpinionTests` cover the parsers; the live shapes were checked on 29 Oct.
- [x] Metadata providers (24 Oct): `MetadataProviders` bundles TMDb + optional TheTVDB + AniDB/Anime-Lists.
      Matcher order for episodes: forced override → AniDB exact title (incl. "2nd Season"/"II"/"Part 2"
      candidates) → Anime-Lists `tmdbtv`/`tmdbseason`/`tmdboffset` → TMDb search (shortening) → TheTVDB
      search bridged to TMDb via remote ids or `/find`. Items are always TMDb-backed. AniDB needs no key
      (daily dump, cached weekly in Caches/metadata/anidb-titles.json; ~2 MB download); TheTVDB needs the
      user's v4 project key (Settings). Toggle "Anime matching" in Settings.
- [x] fanart.tv (24 Oct): `FanartClient`, logo replaces the title in `HeroHeader`, fetched on first open
      of a detail page (`LibraryStore.fetchExtraArt`), weekly. Needs the user's project key (Settings).
- [ ] Duplicate detection UI ("2 versions" badge exists via `files.count > 1`; add preferred-version persistence).
- [x] FTP/SFTP/NFS/DLNA browsing (25 Oct). FTP: Reel's own client (MLSD/LIST, EPSV/PASV, SIZE/MDTM, REST+RETR for
      the AirPlay bridge). DLNA: unicast SSDP to the host, then the well-known description URLs, or a pasted one;
      ContentDirectory Browse with the server's folder tree as the root. SFTP/NFS: `VLCDirectorySource` parses
      directory URLs through VLCKit (sizes and mtimes from its filestat), plays by URL, downloads with the dump
      demuxer; no ranged reads, so AirPlay goes through the HLS copy. Caveat: VLCKit's libssh2 offers only the
      ssh-rsa (SHA-1) host-key algorithm, so SFTP needs a server that still allows it (OpenSSH ≥ 8.8 does not by
      default). Tested against pyftpdlib, MiniDLNA (`brew install minidlna`) and a paramiko SFTP server on the Mac;
      see `Tests/MediaCoreTests/{FTP,DLNA}IntegrationTests` (skip when the servers are down). NFS untested (needs root).
      Discovery: Bonjour (SMB/WebDAV announcements) plus `SourceDiscovery.sweepSubnet()`, which probes every address
      of the Wi-Fi /24 for 445/21/22/2049/5005 and sends each a unicast SSDP M-SEARCH (multicast needs an entitlement).
- [ ] Playlists / Up Next queue beyond next-episode.

Phase 4
- [x] Picture in Picture — done via VLCKit 4 (§3.5). Auto-starts on swipe-home during playback; `pip.enter` button in the player.
- [x] Scrub thumbnails (`ScrubThumbnails`; see "Decoding and the scrubber (1 Nov 2026)").
- [ ] Subtitle style editor (size/colour/position) — VLC `--freetype-*` options at load time.
- [ ] Accessibility pass: VoiceOver through the grids, cards and sheets (the player controls are labelled, see above), Dynamic Type at the larger sizes, reduced motion.
- [x] App icon (24 Oct): letter R in film strip, generated with Codex; see Design/README.md.

Phase 5
- [ ] TestFlight: raise `SWIFT_STRICT_CONCURRENCY`, privacy manifest, 500-file playback corpus (PLAN §11.9).

---

## 8. Things not to do

- Don't statically link VLC or pull in GPL-only VLC modules (breaks the LGPL route and future App Store).
- Don't add ads, IAP or analytics (changes the data-provider terms; owner decided free-no-ads).
- Don't sync or log credentials, playback URLs with embedded passwords, or local file paths.
- Don't rename or modify the user's media files. All fixes are app-side overrides.
- Don't scrape IMDb.
- Don't force-push or rewrite history on the shared branch.

---

## 9. Where the owner's decisions live

`PLAN.md` §6 (decided vs open), §9 (open questions still unanswered: visual style preference, Dolby Vision/Atmos as v1),
§10 (licensing, free sources, sync design). If you need a decision the plan doesn't give, ask the owner; don't guess on anything
that touches licensing, money, or what syncs.

## End credits and Up Next

The Up Next card appears, and its countdown starts, where the end credits begin when that is known,
else at the countdown length plus ten seconds before the end. Two signals, in `PlayerCoordinator.resolveCredits`:
chapters first (`[Chapter].creditsStart(fileDuration:)` in MediaCore: a chapter named Credits/End Credits/
Outro/Ending/ED in the last 15 minutes, or, among unnamed chapters, a final chapter under four minutes in the
last tenth of the file); then a scan of the last stretch of the file (`CreditsMemory.scan`): a frame every 5 s
over the last tenth of the runtime (2–8 min), classified by `CreditsFrame` in Playback (at least three quarters
dark, with two or more rows of light text-like dashes), and `CreditsScan.start` takes the first run of three
credits-like frames after which they stay in the majority. The scan starts 45 s into a play, after the scrub
thumbnails, uses the same thumbnailer, backs off when the device is hot or in Low Power Mode, and its result
(a time or "none") is kept per title in UserDefaults (`reel.creditsMemory`), per device. Episodes only.
Tests: `CreditsDetectionTests`.

## 30 Oct — Intro and credits marks, credits grace, synced marks

- The Up Next countdown now starts a grace period after a *scanned* credits start (15 s; 5 s when the
  start comes from the show's learned credits length; none for a chapter or a hand mark), because the
  frame scan lands up to a keyframe early. `PlayerCoordinator.creditsGrace`.
- The player's More sheet has **Mark this show**: Intro starts here / Intro ends here / Credits start
  here, plus Clear this show's marks and Forget what Reel worked out. `Reel/App/ShowMarkers.swift`.
  Marks win over chapters-less automatic answers. The intro start is fingerprinted (8 frames, 2 s apart,
  `FrameFingerprint`/`IntroLocator` in Playback) and looked for in other episodes' opening minutes as
  they start to play; the intro end gives the length. A credits mark gives the show's credits length,
  and its fingerprints pin the start exactly in episodes whose credits open on the same card.
- Marks sync through CloudKit as one "Document" record per show (`SyncedDocuments` in Sync,
  `ShowMarkersSync` in the app): whole-document, last writer wins.
- Known: the DLNA and FTP integration tests need the local test server and corpus (gone from the
  scratchpad); they fail for that reason alone.

## Audiobooks (30 Oct 2026)

A folder tagged **Audiobooks** (`FolderTag.audiobooks`) is walked for audio files (`AudioFile.audioExtensions`); videos in
it are judged as in a mixed folder. `AudiobookGrouper` (MediaCore, tested) turns the files into books: one m4b per book in
a series folder, a folder of parts as one book, "X 1 of 2"/"X 2 of 2" sibling folders merged. A book is a `MediaItem` of
kind `.audiobook` (`ItemKey.book(sourceID:path:)`, fields `author`, `narrator`, `seriesName`, `seriesIndex`, `coverPath`,
`tagsRead`); its parts are `.episode` items under it (`ItemKey.bookPart`, season 1, episode = part number), so Continue
Watching, up-next, resume and the sleep timer are the series machinery. `MediaItem.isAudiobookPart` keeps intro search,
credits and marks off them. After a scan `AudiobookTags.readPending` parses the first part with VLC for title, author,
narrator, year and cover (or a picture beside the parts), writing them through `LibraryStore.applyBookTags`; covers live
in Application Support/Covers, per device. The Audiobooks section (sidebar, Files tab row) appears only when a book exists.
Debug: `reel://debug-list?path=<folder>&depth=N` logs a source folder's tree.

### Browsing is not adding (30 Oct 2026)
Playing a file from Files or a source's browser leaves a `MediaFile` with classification `browsed`: the
player needs the record, but the matcher and the library ignore it. Long-press a file → **Add to
Library** (a video: its folder is rescanned; audio: **Add to Library as Audiobook** tags the folder
Books via `LibraryStore.adoptAsAudiobooks`). Fix Match has an **Audiobook** segment that does the
same for a title that was read as a film or show; the placeholder title is retired.

### Book metadata (30 Oct 2026)
`Metadata/AudiobookLookup.swift`: `AudibleCatalogClient` (Audible's keyless catalogue search, UK
region by default: ASIN, authors, narrators, series and position, summary, 1000px cover),
`AudnexusClient` (detail by ASIN: plain description, genres) and `AppleBooksClient` (iTunes Search,
the fallback). `AudiobookLookup` ties them together and scores hits (`best` accepts ≥ 0.82 on title
and author). `AudiobookMetadata.lookupPending` (Reel/App) runs after the tags are read, one book at a
time; a clear hit is applied with `LibraryStore.applyBookLookup` (names' title/author stand when the
tags gave them; narrator, series, year, summary, genres, cover and ASIN are filled; the cover goes in
`posterOverrideURL`), otherwise `bookLookup = "none"`. **Fix match** on a book (row long-press, the
page's … menu, or any Fix match on a book) opens `BookMatchView`, which searches and applies the
chosen edition in full. New item fields `asin` and `bookLookup` sync.

## Review pass (30 Oct 2026, evening)
- **Search** (`LibraryStore.search`) matches title, author, series, narrator and episode titles; whole
  titles first, then episodes. Book parts are never results.
- **LibraryStore is split**: `LibraryStore+Audiobooks.swift` and `LibraryStore+Review.swift` are
  extensions; stored properties stay in `LibraryStore.swift`. `notifySync` and `override(for:)` are
  internal for that reason.
- **Tests**: new `LibraryTests` target (`Tests/LibraryTests/LibraryStoreTests.swift`) runs the store
  against `LibrarySchema.container(inMemory: true)`: tags, Needs Review, search, Recently Added, book
  lookups, smart collections, probes. DLNA/FTP integration tests still need their local servers.
- **File probe**: `Playback/MediaProbe` reads length, codec, resolution, audio and subtitle counts
  through VLC without playing; `Reel/App/FileProbe` runs it after scans and at launch for files the
  player has not opened (`filesNeedingProbe`), 25 at a time, not in Low Power Mode or when hot.
- **Missing files**: `MediaFile.missedScans` counts scans that should have shown a file while its
  folder would not list; three running and the file is treated as gone (`LibraryScanner`).
- **Smart collections sync**: rules are `MediaCollection` rows with `smartRules` (JSON), so they
  travel with CloudKit; `SmartCollectionStore` reads them from the store and migrated the old
  UserDefaults rules once. `collections()` hides them; `smartCollections()` lists them.
- **Audiobooks**: Settings → Metadata → Audible store (`AppSettings.audibleRegion`); Audiobooks
  sort (author/title/added) and filter (all/in progress/not started/finished); chapters VLC read on
  play are listed under each part and open the part there (`PlayerCoordinator.play(startAt:)`);
  the tab bar falls back to Home if the last book goes; duplicate folder rules are removed at launch.
- **Settings** is a short top level (Library, Preferences, iCloud, Storage, About, Reset) with pages
  in `Settings/SettingsPages.swift`: Metadata, Playback, Subtitles, Scanning.
- Still per device: nothing of note. Widgets still wait on the App Group entitlement (Developer portal).

## Screenshots (31 Oct 2026)

The iPad set in `docs/screenshots`, `docs/app-store/screenshots/raw` and the framed `ipad-13` set
were retaken on the iPad Pro 13-inch simulator (light mode, status bar overridden to 9:41), and the
iPhone sets on the iPhone 17 Pro Max (raw and 6.9") and iPhone 17 Pro (6.1"); `seed.sh`, `finish.sh`
and `shoot.sh` in that session's scratchpad did the seeding and the walk, as described here. The
library is a stand-in corpus, since the old WebDAV test library is gone: ffmpeg clips from the
demo backdrops named like real films and episodes, and tiny tagged `.m4b` files for the books, in
a scratchpad folder served by wsgidav on 127.0.0.1:8080 without a password. The scanner reads only
names, TMDb and Audible supply the rest. Steps:

1. `reel://addsource?type=webdav&host=127.0.0.1&port=8080&path=/&name=Media&tls=0&tags=Films:films,TV:tv,Books:audiobooks`
   written to `Documents/command.txt` (Debug builds). The new `tags` parameter sets folder rules.
2. Watch states, favourites and plausible file sizes, lengths and codecs are written straight
   into `Reel.store` with sqlite while the app is terminated (a hand-written collection row crashed
   the app: SwiftData's encoding of `itemKeys` is not JSON, so collections stay empty).
3. `reel://open/<section>` and `reel://item?title=` drive the pages; `xcrun simctl io screenshot`.
   The player: `reel://play?title=Firefly` on a ten-minute `gradients` clip, one tap for controls.
4. `Scripts/app-store-screenshot.sh` frames the raw PNGs with the captions on the old set, plus
   "Audiobooks, by author and series".

Two bugs the shots found and fixed: a single-file book in an author-named folder took the author
as its series (`LibraryStore.dropSeriesNamedAfterAuthor`, applied by tags, lookup and the scanner),
and a part of a book had no cover on Home or in History (the part now borrows the book's chosen
cover). History says "Part 1" for a book, not "S01E01".

## TestFlight upload (31 Oct 2026)

No Xcode Cloud workflow exists; builds are archived on Paul's Mac and uploaded by `xcodebuild`. Xcode is
signed into Paul's Apple ID, so automatic signing fetches the distribution certificate and profile on
demand (`-allowProvisioningUpdates`); nothing is in the keychain beyond the development identity. Bump
`CURRENT_PROJECT_VERSION` in `project.yml`, `xcodegen generate`, then:

```sh
xcodebuild -project Reel.xcodeproj -scheme Reel -configuration Release -destination 'generic/platform=iOS' \
  -archivePath /tmp/Reel.xcarchive -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath /tmp/Reel.xcarchive -exportOptionsPlist ExportOptions.plist \
  -exportPath /tmp/export -allowProvisioningUpdates
```

`ExportOptions.plist`: method `app-store-connect`, destination `upload`, teamID `834D8P4J32`, signingStyle
`automatic`, uploadSymbols true, manageAppVersionAndBuildNumber false. The export step uploads and waits
for "Upload succeeded"; processing takes a few minutes before the build appears under TestFlight.

The App Store Connect listing (version 1.0, "Prepare for Submission") was filled from
`docs/app-store/listing.md` on 31 Oct: subtitle, promo text, description, keywords, URLs on
reel.ketelle.co.uk, six iPhone shots (6.1" set) and seven iPad shots (13" set). The site's React form
ignores programmatic value changes; fields were filled by typing. The 6.9" iPhone set is not uploaded
separately: App Store Connect scales the medium-display set to every iPhone size.

## Decoding and the scrubber (1 Nov 2026)

The iPad's diagnostics for a 1080p 10-bit HEVC MKV showed the picture stop while the sound ran, 39 s
after a 76 s pause; the stall watchdog reloaded it 6 s later. VLC's own log (`Documents/Diagnostics/vlc.log`,
pull it with `xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier
uk.co.ketelle.reel --source Documents/Diagnostics/vlc.log`) gave the cause: the engine pinned the decoder
to ffmpeg (`:codec=avcodec` plus `:avcodec-hw=videotoolbox`, the recipe PLAN.md used to give). On Apple
platforms VLC's hardware decoding is a separate `videotoolbox` decoder module, not an ffmpeg
acceleration, and the pin kept it out of the candidate list ("looking for video decoder module matching
avcodec"). Every title Reel had ever played was decoded on the CPU. This one decoded to 10-bit planar
(I0AL), which VLC's zero-copy converter cannot take, so swscale converted every frame to BGRA on the CPU
as well: 1080p 10-bit HEVC plus a full-frame conversion, 24 times a second, which is the iPad's limit.

Now nothing is pinned while hardware decoding is on, so VLC's VideoToolbox module takes H.264 and HEVC
and hands the display hardware surfaces; VLC falls back to ffmpeg on its own when it refuses a stream.
Off, or for a codec whose hardware output is wrong on the iPad (`PlayerCoordinator.needsSoftwareDecoding`:
MPEG-4 Part 2 comes out black or green), `:codec=avcodec` and `:avcodec-hw=none` force software as
before; the option is now decided per file from the probe's codec. `ScrubPreview` follows the same rule.
Check on a device: `vlc.log` says `using video decoder module "videotoolbox"` for an H.264 or HEVC
title. VLCKit's `VLCMediaThumbnailer` pins `codec=avcodec,none` itself, so the scrubber thumbnails and
the credits scan still decode in software; the frame grabber and the thumbnail shim force software too
(hardware surfaces arrive blank through the vmem output).

The scrubber strip is fed from playback when VLC can manage it: on each clock tick, when playback passes
the middle of a strip slot that has no frame, the engine writes a vout snapshot (`saveSnapshot`, a 320 px
PNG written by VLC's video thread) and `ScrubThumbnails.capture` files it as that slot's frame. That only
works for software-decoded titles (the MPEG-4 Part 2 AVIs): for a hardware-decoded one VLC logs "Failed
to convert image for snapshot", there being no converter from a VideoToolbox surface back to RGB in this
build, so after the first miss the title is left to the thumbnailer (`snapshotWarned`). The same missing
converter is why thumbnails cannot be made with the hardware decoder. The thumbnailer pass makes what
is left: every ninth frame first, then the frames ahead of the playhead in
order, then those behind it. It stops when another title takes the screen (`ScrubThumbnails.focus`);
before, a title skipped past in seconds got its whole 131-open pass alongside the current title's. The
live preview's canvas covers the strip frame only once a picture has actually been displayed
(`statistics.displayedPictures`), not as soon as the video output exists, which could leave a black
canvas over a frame the strip already had. The preview is a still: after each seek the player runs
until the first new picture after the seek has landed, then pauses. It used to wait on time ticks plus
a delay, which with the hardware decoder showed up to a second of motion in the bubble; the settle now
counts displayed pictures, and logs "scrub preview did not hold" if pictures keep coming after the pause.

Two more findings from the same afternoon, both about `:start-time` in libvlc 4. Seeks and reported
times are relative to the start-time range: the preview opened at 50 s and seeked to 90 s showed the
picture from 140 s while reporting 90, so the preview no longer uses `:start-time` and applies the
wanted time as its first seek instead (the canvas stays hidden until a picture from after that seek
has shown). VLCKit's `VLCMediaThumbnailer` places its frame at its default position 0.3 inside that
range whatever `snapshotPosition` says, so every strip frame sat 30% of the way from its start time
to the end of the file (the scrub-v3 and v5 caches, now deleted on launch; the strip is scrub-v6).
The strip now comes from the shim's `libvlc_media_thumbnail_request_by_time` with a fast seek
(`PreciseThumbnail.frame(fast:)`), which takes an absolute time; checked in the simulator against a
clip with a burned-in clock: frames at 0:10, 0:50, 1:30, 2:10, 2:50 for a 3-minute file, and the
preview at 1:30.8 for the 1:31 mark. `Packages/ReelKit` tests: the DLNA integration test fails when
a MiniDLNA on 127.0.0.1:8200 serves a library without the demo film; it is unrelated to playback.

## Website moved to the studio (5 Nov 2026)

Reel's pages now live on the studio site, served from the `studio/` app in dripster82/iphonegames
(content in its seed file; the server's copy is imported from the studio admin, Apps → "Import an app
from the seed file" with `reel`): https://studio.ketelle.co.uk/reel/ plus `/reel/support/`,
`/reel/privacy/` and `/reel/terms/`. Settings, the README, the metadata user agent and
`docs/app-store/listing.md` point there, and the support address is support@ketelle.co.uk (subject
"Reel App Support"), the same on the studio pages. The old `docs/` pages are now redirects to the studio (meta refresh, so GitHub Pages redirects too; `sudo vps deploy reel` picks them up on reel.ketelle.co.uk). Keep them until
reel.ketelle.co.uk and the GitHub Pages site redirect to the studio; after that remove the `reel` VPS
app and delete `docs/*.html` and the icons (the screenshots and `docs/app-store`
stay). App Store Connect's support, marketing and privacy URLs and the terms line in the description
must be changed to the studio URLs by hand.

## Freeze after a long pause (5 Nov 2026)

The iPad froze again after a 12-minute pause, with the decoder fix in. Its VLC log has the cause: after
every ordinary pause VLC logs "resetting master clock: coefficient too unstable" and plays on; after
this one it logged "picture displayed late (missing 725625 ms)" and then dropped 323 pictures as "too
late" for the one it showed, each late by the length of the pause, until Paul scrubbed and the seek
("ES_OUT_RESET_PCR", a new clock context) cured it. The difference: eight minutes into any pause iOS
takes the audio session (`reel.log` "audio session interrupted while paused", always at +8:00, no
other app involved), and VLC's clock comes back from a pause whose audio output was taken without
accounting for the pause. `VLCPlaybackEngine` now notes an interruption that begins while paused
(`clockStaleAfterInterruption`) and, on the next `play()`, seeks to the current time right after
`player.play()`, with the seek watchdog armed: the seek is what gave VLC the fresh clock in the log.
A load clears the flag. The stall watchdogs had not fired yet (the scrub came 12 s after the resume;
the no-output watchdog would have reloaded at about 10 s), and remain the guard, not the fix.
Not yet verified on the iPad with a real 8-minute-plus pause: look for "audio session was taken
during the pause; seeking to Ns" followed by normal play in `reel.log`.

- Later that evening it froze again after an 8-minute pause in the PiP window. The resume came
  through `PiPMediaController.play()`, which called the VLC player directly and so never ran the
  engine's `play()` (no "seeking to Ns" line in the log). PiP play now goes through the engine's
  `play()` on the main actor (`onPlay`), logged as "play from the PiP window". Still unverified
  with a real PiP pause of over eight minutes.
- 6 Nov: the iPhone froze the same way after a 2.6-minute pause in the foreground, with no audio
  interruption at all: its VLC log shows "resuming" then "picture displayed late (missing 160594
  ms)" and 278 pictures dropped as too late, while a 4-minute pause a quarter of an hour earlier
  had recovered by luck ("resetting master clock: coefficient too unstable", a new clock context).
  So the clock failing to come back is a property of long pauses, not of the session being taken.
  The engine now notes when a pause began (`pausedAt`) and `play()` after a pause of over five
  seconds (`longPause`) does the same seek, logged "paused for Ns; seeking to Ns so VLC starts a
  fresh clock"; the interruption flag remains for the eight-minute case. The seek costs only a
  moment's picture on resume, and nobody knows the shortest pause that breaks the clock, so only
  a tap-pause short enough to want a seamless resume is left alone. Unverified on a device: pause
  for a minute, play,
  and look for that line followed by moving pictures.

## PiP stops starting after a return from the background (6 Nov 2026)

iPad log: every swipe-up had started a window (the explicit ask on `.inactive` fails on the iPad
every time with "Failed to start picture in picture", and the automatic start from inline then
opens the window half a second later), until the app came back from the background with the
video paused and no window open. On that return the display layer reported itself failed
("display layer failed (Operation Interrupted) after the background; flushing"); the flush had it
painting again, but from then on every swipe-up failed, explicit and automatic alike, for the rest
of the session. The controller made over a layer that has failed is done for. `ReelPictureInPicture.rebuild`
now makes a fresh controller over the same layer when `flushDisplayLayerIfNeeded` finds the PiP
layer failed, logged "PiP: controller made afresh (the display layer had failed)". Not reproduced
on the simulator (the test clip is too short to get a pause, a background and a return in).

- Later that evening the iPad showed the remake is the right cure but not at any moment: the
  controller remade at 22:14 after a failed layer, with the video paused and the layer just
  flushed, never started a window (the next swipe-up, at 22:42, failed), while one remade at 22:43
  on another failed layer, with the video playing, started a window a second later. And the
  simulator showed a remake made as the scene goes inactive loses the automatic start that follows
  it. So a remake is only *asked for* (`ReelPictureInPicture.needsRebuild`, set when the layer has
  failed and when a start fails) and done by the engine at the next good moment: playing, in the
  foreground, no window open (`rebuildPictureInPictureIfNeeded`, from the attach on `.playing` and
  from the return to the foreground), logged "PiP: controller made afresh (…)". The explicit ask
  on `.inactive` fails on the iPad and the simulator every time; the automatic start from inline
  half a second later is what opens the window.

## White screen at launch after a power-off (15 Nov 2026)

The iPad's battery ran flat (a LowBatteryLog at 16:28 in the system crash logs); after the
power-on Paul opened Reel and got a white screen and nothing else. No Reel crash or hang report
exists for the day, and the Reel log has **nothing at all** for that launch, not even
"scene active". Launched from the Mac forty minutes later the app came up in under a second. So
whatever it was belonged to the first minutes after the reboot, and it stopped the launch before
anything in Reel logs: the launch screen (white) stays up while the main thread is busy in
`ReelApp.init` or the first body, and the launch watchdog is lenient while the system is still
settling after a boot, which is how a white screen can sit there instead of a kill.

Unproven, so two things were done:

- **Launch trace** (`Reel/App/LaunchTrace.swift`). `ReelApp.init` marks each step (opening the
  library store, settings, sync engine, show marks, player and the VLC library, downloads and
  stores, background scans, VLC sources, first body), `RootView.onAppear` logs
  "launch: first frame after 0.49s (opening the library store 0.11s, first body 0.36s)", and a
  timer off the main thread logs at 5, 15 and 30 s "launch: no first frame after Ns; still in
  "<step>" for Ns" if the first frame has not come. The next white screen names its step.
- **Keychain read moved off the launch path.** `AppSettings.init` read the OpenSubtitles password
  synchronously from the Keychain, an iCloud-synchronised item, on the main thread; Keychain
  reads shortly after a boot are a known place for a long block while the security daemons come
  up. It is now read in a detached task after init (`loadingPassword` keeps the setter's
  Keychain save from firing for that fill). The source passwords were already read only when a
  source connects, off the main thread.

Then the launch was restructured so the slow services come up behind a splash rather than
before the first frame (Paul's ask, 15 Nov evening):

- `ReelApp.init` now does only what is cheap and local: the SwiftData container, the stores,
  settings from UserDefaults, the sync engine *object* (no CloudKit start), the player
  coordinator (no VLC: `VLCPlaybackEngine.player` is a lazy var, and the first VLCMediaPlayer is
  what brings up the shared VLCLibrary and its plugin load), the background-task registration
  (must happen before launch finishes) and the VLC source factory.
- `LaunchSequence` (`Reel/App/LaunchTrace.swift`) runs from a `.task` on the window after the
  first frame: "Preparing the player" (`engine.warmUp()`), "Opening the VLC log" (debug builds),
  "Starting iCloud sync" (`SyncEngine.startIfEnabled`), "Checking show marks"
  (`ShowMarkers.retryEarlySearchesOnce`). Each step publishes its name, sleeps 40 ms so the
  splash draws it, then runs; a step that blocks the main thread leaves its name on screen.
- `LaunchView` is the splash over `RootView` until `ready`: app glyph, "Reel", spinner and the
  step name; it fades when the sequence ends. On the simulator the whole launch reads
  "first frame after 0.60s" then "ready after 1.26s (… Preparing the player 0.43s …)"; the
  splash is on screen for about two thirds of a second.
- `LaunchTrace.watch` now reports against *ready*, so it says "no first frame" or "first frame
  drawn, not ready" with the step name at 5, 15 and 30 s.

The first real catch (15 Nov, 20:09): Paul saw the splash sit on its last line. The trace read
"first frame after 0.53s", then "not ready after 5s; still in Checking show marks for 13.5s"
*logged at 14.5 s*, and "ready after 23.21s (… Starting iCloud sync 0.21s, Checking show marks
21.73s)". The sync start took a fifth of a second; the step after it waited 21 s for its turn,
and the 5 s timer, which runs off the main thread, fired 9.5 s late: the whole process was
starved or suspended, not blocked in CloudKit. No "scene active" was logged for that launch,
which points at iOS having brought the app up in the background (a background task or push, or
prewarming), where timers are held and CPU is scarce, with the splash still up when Paul opened
it. Whatever the trigger, nothing to do with iCloud or the network now gates the splash:
`LaunchSequence` is ready after the VLC warm-up (and the debug VLC log), and the sync start and
the marks migration run a second after Home is up, timed and logged only when slow ("launch:
sync start and show marks took Ns after Home was up"). The first-frame line now says "(in the
background)" or "(inactive)" when the app was not active at its first frame, and a late watch
timer says so: "(this timer fired Ns late: the process was starved or suspended)". An iPad used
offline comes up the same way; CloudKit's traffic is asynchronous and its errors (CKError 20,
"cancelled", at 20:09:59 that evening as the app went to the background) are logged and retried.

Paul then asked why the VLC log held the start at all (it showed as "Opening the VLC log 0.28s").
It is debug-only diagnostics: `HLSRemuxer.enableVLCLog` truncates `Documents/Diagnostics/vlc.log`
and attaches a `VLCFileLogger` (credentials redacted) to the shared VLCLibrary so libvlc's own
messages are kept; that file is what showed the SMB socket dying on 15 Nov. Measuring showed the
library itself was already up (`warmUpLibrary` 0.00 s) and the half second was `VLCMediaPlayer()`,
which has to be made on the main actor. So now **nothing gates Home**: `LaunchSequence` sets
`ready` at once (the splash lasts a frame), the library warm-up and the VLC log run on a utility
thread (`enableVLCLog` and `fileLogger` are `nonisolated`), and one second after Home has painted
the player object is made (`engine.warmUp()`, so the first play does not pay for it; a play that
comes first makes it on demand through the lazy `player`) followed by the sync start and the marks
migration. Only slow ones log ("launch: after Home, the VLC player took Ns and the sync start Ns").

Paul's reboot test after that (20:33) froze on the splash's "Starting…" line anyway, and the log
explained it: "ready after 0.44s", "first frame after 0.53s", "scene active" a second later, then
"VLC library and log took 13.62s off the main thread". VLC's shared library, the module bank
loading and probing every plugin, took 13.6 s in the first minute after the reboot (half a second
warm). The player object made one second after Home was on the main thread, and
`VLCMediaPlayer()` waits inside `VLCLibrary.shared()` for that same start, so the main thread
froze and the screen kept its last frame, the splash. Now **no VLC object is touched on the main
thread until the library is up**: `VLCPlaybackEngine.startWarmingLibrary` runs it on a
user-initiated task (utility was starved for 22 s after the boot), `libraryIsReady` says when,
`awaitLibrary()` waits; `warmUp()` makes the player only after that; `load()` before it sets
`.opening`, logs "waiting for VLC's library before the load" and performs the load when it is up
(a later load or stop supersedes it via `loadGeneration`), while the coordinator shows "Preparing
the player…" under the spinner (`loadingMessage` now shows whenever the spinner is up and clears
on `.playing`); `ScrubPreview`'s player is lazy too, since `ScrubPreview.shared` is made when
PlayerView appears. The library's own time is logged when over half a second ("launch: VLC's
library took Ns to come up, off the main thread").

Paul's next reboot (21:01) was slow again, and this time every launch number was good: ready
0.49 s, first frame 0.59 s, VLC's library 0.7 s, "scene active" at 1 s. The clue is further down:
the tasks the activation schedules for 6 and 8 s later ("scan on launch", the book tidy and
probe) ran at 21:02:02, **a minute late**, so the main thread was saturated for most of that
minute by work that was not timed. So the instrumentation moved from launch to the main thread
as a whole:

- `Diagnostics.startMainThreadWatch()` (from `ReelApp.init`): a thread pings the main thread four
  times a second and logs "[main] main thread busy for Ns (from … until … UTC)" for every
  stretch of a second or more with no answer, or "process starved or suspended for about Ns"
  when the watch thread itself ran late.
- `Diagnostics.timeMain(name) { … }` wraps the known main-thread jobs and logs "[main] <job> took
  Ns on the main thread" at half a second or more: Home's three row chunks and its refresh after
  a store change, the scan progress publish, the sync engine's record building, its post-fetch
  bookkeeping and its sent-records bookkeeping, and the post-launch book tidy and probe.
  "scan on launch starting" is logged too.
- One hog fixed on the way: `nextRecordZoneChangeBatch` hopped to the main actor once per record,
  up to 200 per batch, each a SwiftData fetch; it now builds the batch's records in one hop.

Read the next slow launch's log for "[main]" lines in the first minute after "scene active": a
busy stretch with a named job in it is the answer; a busy stretch with no job named is work not
yet wrapped, and the candidates are the screens' own bodies (RootView fetches `sources()` and
`audiobooks()` in its body) and SwiftUI's rebuilds on `LibraryStore.objectWillChange`.

**Caught (21:16, the log AirDropped from the iPad because the Mac's developer connection does not
see the iPad for a while after a reboot):** "ready after 0.50s", "scene active" at 21:16:55, then
"VLC's library took 32.9s to come up, off the main thread" and "[main] main thread busy for 32.4s
(from 21:16:55 until 21:17:27)" with **no named job inside**. Paul had tapped Continue Watching:
the player screen's `VLCVideoView` set `engine.drawable`, the drawable setter touched `player`,
the first `VLCMediaPlayer()` waits inside VLCKit for the shared library, and the main thread sat
there for the library's whole 33 s. (33 s for the library after a reboot on this iPad Pro 4th gen;
0.5–0.7 s warm. Nothing to be done about the library itself; everything about not waiting for
it.) So the engine's player is now behind two accessors: `player` makes it (and applies a
`pendingDrawable`), and `playerIfMade` returns it only if it exists or the library is ready.
Every entry a view can reach before the first load goes through `playerIfMade`: the `drawable`
getter and setter (a drawable set early is kept and applied when the player is made), `applyFill`,
`attachDisplayLayerIfNeeded`, `flushDisplayLayerIfNeeded`, `setRate`, the stats readers
(`verifyOutput`, `hasSelectedAudio`, the tick's length read, the failure report). `load()` already
waited for the library with "Preparing the player…". The screen therefore stays live while the
library comes up, and the play starts when it is there.

The 22:41 reboot (Paul's tap on Continue Watching within a second of Home) did it again with
that build: ready 0.47 s, then "main thread busy for 19.3s (from 22:41:06 until 22:41:25)" against
"VLC's library took 19.8s", and no "waiting for VLC's library before the load" line, so yet
another touch of `player` on the main thread, not the drawable. Rather than guess a third time,
the `player` getter now **logs its caller** when it makes the player before the library is ready
("VLC player made before the library is ready (this blocks): <frames>"), and the remaining entry
points a view or the coordinator can reach before a load are guarded with `playerIfMade`:
`stop(forReload:)` (reached through `engine.stop()` from `dismiss`), `play()` (the resume),
`pause()`, `togglePlayPause()`, `seek(to:)`, `setSubtitleDelay`, `setAudioDelay`, and the session
report. The next slow launch's log will name whoever is left.

**22:50, with a screen recording:** the splash's "Starting…" for 27 s, Paul touched nothing. The
log: ready 0.76 s, "scene active" at 22:51:00, "VLC's library took 26.3s", "main thread busy for
25.5s (from 22:51:00 until 22:51:25)", and **no** "VLC player made before the library is ready"
line. So nothing in Reel touched VLC on the main thread, and the main thread still froze for
exactly the library's start, as in all four runs (32.4/32.9, 19.3/19.8, 25.5/26.3 s). The
vendored VLCKit's modules are compiled in (`_vlc_static_modules`, no plugin dylibs), so it is
not the dynamic loader's lock either; what inside `libvlc_new` stalls the main thread for its
whole duration is not known. What is known is that the freeze follows the library start. So the
**library is no longer started at launch**: `LaunchSequence` only sets the `onLibraryReady` hook
(the debug VLC log); `startWarmingLibrary` runs from the first `load()` (behind the opening
spinner and "Preparing the player…") or `warmUp`, and logs "VLC's library took Ns" itself. The
main-thread watch's busy line adds "; VLC's library start was running" when that coincides
(`Diagnostics.backgroundStartInProgress`, set in `ReelApp.init`). After a reboot Home should now
be instant and the first play should wait on the spinner; if the main thread still freezes
during that first play, the busy line will say the library was running, and the next step is to
find out what `libvlc_new` does that the main thread waits on (a sysdiagnose during the stall,
or timing `VLCLibrary(options:)` with modules disabled one group at a time).

**23:12, the decisive one:** with VLC no longer started at launch, the reboot launch froze just
the same: "scene active" 23:12:42, "main thread busy for 25.6s (from 23:12:42 until 23:13:07)",
**no VLC start at all** and no named job. VLC was never the cause; its start merely ran during the
same freeze. The freeze begins at activation and lasts 20–33 s on every launch in the first
minutes after a reboot, and nothing wrapped so far is inside it. Guessing stopped there: the
main-thread watch now **samples the main thread's call stack** while it is silent, at 2, 5 and
12 s into a stall (`MainThreadSampler` in Diagnostics.swift: `thread_suspend`,
`thread_get_state`, a frame-pointer walk read with `vm_read_overwrite`, `thread_resume`, then
`dladdr` after the resume because it takes the loader lock), logged as "[main] main thread at
Ns into the stall: frame < frame < …". Swift names are mangled in the log; `swift demangle` on
the Mac reads them. `reel://debug-stall?seconds=7` (debug builds) blocks the main thread to
exercise it; on the simulator the samples show `Thread.sleep` under `ReelApp.open`. The next
post-reboot launch's log says exactly what the main thread is doing for those 25 s.

**16 Nov 07:43, the stacks (build 0b39b0b, iPad rebooted 07:42).** Reel opened at 07:43:05,
Home ready in 0.5 s, "scene active" 07:43:06, then "main thread busy for 35.9s". The three
samples were all **inside SwiftUI's own render pass**, each in a different phase of one CoreAnimation
commit: 2 s in `ViewGraph.setRoot` under `GraphHost.flushTransactions`, 5 s in
`GraphHost.updatePreferences` / `ViewGraph.updateOutputs`, 12 s in
`ViewGraph.renderDisplayList` → `_UIHostingView` → `objc_loadWeakRetained`. No Reel frame, no
blocking call (no `mach_msg`, `read`, lock or sleep): the main thread is *executing* framework
code slowly, mid-instruction every time. None of the `timeMain` jobs fired, so Reel's own bodies
were quick. A second stall the same minute, in the background (07:43:59–07:44:25, 25.5 s), was a
**SwiftData fetch on the main thread** sitting in `sqlite3_step` → `memmove`/`memset` under
`NSManagedObjectContext.performAndWait` (the caller was past the 40-frame cap). Alongside it an
SMB connect took 16.0 s (0.2 s normally) and CloudKit cancelled an operation.

Reading: every first-touch after a reboot is 50× slow — VLC's library start (20–33 s vs 0.5 s),
SwiftUI's first big render, a sqlite read, an SMB connect — and the common factor is **cold
storage and a busy system**, not a particular piece of Reel: code pages of SwiftUICore,
AttributeGraph and Reel's own very large debug binary (VLC's modules are statically linked) are
paged in from flash on first use while iPadOS runs its post-boot work. A page fault looks exactly
like the samples above: the faulting instruction's frame, no syscall. To settle it rather than
argue it, the sampler now records, with each sample and in the busy line, the **main thread's
CPU time and scheduler state and the process's page-ins and faults since the stall was noticed**
(`MainThreadSampler.stats`: `thread_info(THREAD_BASIC_INFO)` + `task_info(TASK_EVENTS_INFO)`),
e.g. "(CPU 0.3s, waiting; process page-ins +826, faults +1116)". CPU close to the wall time means
the thread is computing (a slow CPU or expensive work); little CPU with thousands of page-ins
means it is waiting for pages from storage. Samples now also come at 25 s, walk 96 frames, and
fold runs of `<redacted>` frames per image ("CoreData ×9") so the Reel frames at the bottom of a
deep SwiftData stack are kept. On the simulator a forced `debug-stall` reads "CPU 0.0s, waiting".

If the page-in reading is confirmed, the fixes are about touching less at first launch, not about
finding a culprit: the SwiftData fetch must leave the main thread (find its caller in the folded
stack), Home should draw from a small cached snapshot rather than the store, and a Release build
(smaller, optimised; the TestFlight build) should be timed after a reboot against the Debug one,
since every device run so far has been Debug.

**16 Nov 10:44, measured (build 954a90d).** Storage is **not** it. The same 35 s stall at
activation read: "CPU 34.0s, waiting uninterruptibly; process page-ins +898, faults +20853" at the
end, and at 2/5/12/25 s "CPU 1.0 / 4.0 / 11.0 / 24.0s, running" — the main thread was on a CPU
for 34 of the 35 s, executing. The four stacks were again all in SwiftUI's render pass with **no
Reel frame** in any of them (`updateOutputs` → UIKit → `memmove`; `flushTransactions` →
`AGGraphSetOutputValue` → malloc; `AGGraphGetWeakValue`; `Update.dispatchActions` → UIKit ×18 →
`CFString`). So it is roughly 70× the work of the warm 0.5 s render, done by the framework itself in
a single CoreAnimation commit (the run loop never turned: no pong for 35 s). Reel's own bodies, if
they ran thousands of times in a Debug build, would almost certainly have been caught by one of the
four samples; they were not. Open question: what makes SwiftUI's graph do 70× more work only in the
first minutes after a reboot. A second stall the same minute, in the background, was
`scanForNewMediaIfDue` → `LibraryStore.sources()` sqlite fetch, then `AppSettings.tvmaze` lazy
init → `TVmazeClient` → **a Keychain read (`SecItemCopyMatching`) on the main thread** waiting on
securityd, then the process was suspended by iOS ("process starved or suspended for about 25.9s").
That one is cheap to fix later (the TVmaze key read should leave the main thread) but is not the
launch freeze.

The instrument was sharpened again for the next reboot: samples **once a second from 2 s to 40 s**,
CPU split into **user + kernel** (kernel-heavy means page-fault or VM work charged to the thread,
user-heavy means real computation), and **event counters** — `Diagnostics.count(name)` is called
from `RootView.body`, `HomeView.body` and Home's `library.objectWillChange` sink, and the busy line
ends with "; during it: Home body ×N, Root body ×N, library change ×N". A body count in the
thousands is an invalidation storm (then find the publisher); a count of one with 34 s of user CPU
is a single pathological framework pass (then bisect Home's rows: a build with Home showing a plain
label after a reboot would tell whether the content matters at all). Also worth one reboot each:
does the **iPhone** show it, and does a **Release** build.

**16 Nov 11:19, counted (build 493aff2).** Activation stall 13.8 s, "CPU 12.5s = user 12.5 +
kernel 0.0, running; page-ins +648" and **no counters at all: zero Root bodies, zero Home bodies,
zero library changes during it.** Twelve one-second samples, all framework-internal, cycling through
`ViewGraph.setRoot` (at 2 s and again at 9 s), `GraphHost.flushTransactions`,
`Update.dispatchActions` → UIKit ×18 → `_UITraitTokenSetEnumerate`, and
`ViewRendererHost.performExternalUpdate` → UIKit → `class_createInstance`. So: not an invalidation
storm (no body ran), not storage (no kernel time, few page-ins), but SwiftUI's own layout and
hosting machinery — the UIKit hosting views inside `NavigationSplitView` / `NavigationStack` being
re-rooted and trait-updated, in pure user CPU, for 13 s, with Reel's bodies never consulted. Reel has
no `UIHostingController` of its own; the representables are all in the player. Every device run so
far was a **Debug** build with Xcode's debug dylib (`Reel.debug.dylib`,
`__debug_main_executable_dylib_entry_point` at the bottom of every stack). The next test is a
Release build after a reboot: if it launches cleanly, the freeze is a Debug-build artefact that the
TestFlight build never shows. If it does not, the next bisection is a one-shot debug flag that makes
`RootView` show a plain label, to see whether the split view itself is the cost.

The background stall the same minute was different from 10:46 and is Reel's to fix later:
`scanForNewMediaIfDue` → `LibraryStore.items(kind:includeHidden:)` → `playable(_:)` →
`MediaItem.files` / `.episodes` / `.show` — SwiftData relationship loads **per item on the main
thread**, each a sqlite `pread`, 25.6 s wall for 0.6 s CPU (waiting on storage, then suspended by
iOS in the background). An N+1 that is harmless warm and long cold; it should prefetch or run off
the main actor.

**16 Nov 11:26, Release build: the same.** 26.8 s at activation, "CPU 25.5s = user 25.5 + kernel
0.0, running", no debug dylib anywhere, no Reel frame, no body count. Not a Debug artefact: TestFlight
users get this too. Twenty-five one-second samples cycled through the same framework places, now with
`_NSStringFromUIContentSizeCategory` under `_UITraitTokenSetEnumerate` ×19-deep in UIKit under
`Update.dispatchActions`, `_UIHostingView.requestUpdate` / `beginTransaction`, `setRoot` three
times in a row at 15–19 s. UIKit is walking trait collections (content size category among them) for
SwiftUI's hosting views, for 25 s of CPU, with Reel's bodies never run. A web search found no report
of it. The bisection is armed: `reel://debug-plain-root` (debug builds; also droppable into
`Documents/command.txt`) sets `reel.debugPlainRootOnce`, and the next launch's `RootView` is a plain
label for that one launch ("plain root test launch (flag cleared)" in the log). Freeze still there →
the shell (`ReelApp` scene, environment objects, `preferredColorScheme`, the launch overlay) or
iPadOS itself; freeze gone → bisect the split view and its screens next.

**16 Nov 11:33, plain root: no freeze at all** (ready 0.14 s, first frame 0.41 s, scene active, not
one busy line). The shell (`ReelApp` scene, environment objects, launch overlay, `preferredColorScheme`)
and iPadOS are cleared; the cost is in the split view and its screens. A relaunch of the **normal**
tree three minutes after that reboot (11:35) was clean too, so either only the first launch after a
reboot pays, or the window had closed by then; the next reboot separates them (plain launch first,
normal tree straight after). The flag is now levelled, `reel://debug-plain-root?level=N`
(`reel.debugPlainRootLevel`, one launch, then cleared; the log says "root test level N launch"):
1 plain label · 2 split view + sidebar `List` + empty detail · 3 `NavigationStack { HomeView() }`
alone · 4 split view + sidebar + `NavigationStack { Text }`. Levels 2 and 3 split the tree in half:
2 freezing blames the sidebar list / split view (UIKit-hosted cells, SF Symbol labels); 3 freezing
blames Home's content.

**16 Nov 11:44, two launches in one reboot.** Level 1 armed, reboot 11:42:10, launch at 11:43:56
(+1:46), then `--terminate-existing` relaunch of the normal tree at 11:44:09. The first process left
**no log lines at all** (the `Diagnostics.log` queue is utility QoS; its writes were lost to the kill
on a busy system — don't kill a process whose lines you need), but the flag was consumed (the
second launch drew the normal tree: Home body ran). The normal tree, first drawn at +2:00 after the
reboot, had a **2.6 s** stall instead of 25–36 s. Together with 11:33/11:35 that is twice: a plain
launch first, then a normal launch soon after is nearly clean. Two readings still fit every run:
(a) a per-boot cost that the first Reel process pays and the next does not, whatever the first drew;
(b) a slow window of roughly 90 s after boot (every stalling launch so far was drawn at +0:40 to
+1:35; the clean ones at +2:00 and +3:05), during which everything is slow — the first VLC library
start (20–33 s), SMB connects (16 s), Keychain, sqlite `pread`s — and SwiftUI's first big render
with it. (b) fits the other slow things; (a) fits the CPU-bound reading less well, since the CPU was
ours the whole time. Decisive next test: reboot, **touch nothing for three minutes**, then launch
the normal tree as the first process. Stall → (a); clean → (b), and the fix is about what the user
sees in that window, not about Reel's tree.

**16 Nov 11:53, decided: it is the boot window.** Reboot 11:49:58, nothing touched, Reel launched as
the first process at +3:03: ready 0.46 s, first frame 0.56 s, scene active, **no stall**. The
per-boot-cost reading is dead, and `Library/Caches/com.apple.dyld/Reel.dyld4` kept its 11:43 time
(that rewrite came from the 11:40 install, not the reboot). So: for roughly the first two minutes
after an iPad reboot the device is slow, everything in it (SMB connect 16 s, Keychain, sqlite reads,
VLC's library 20–33 s), and Reel's first full render, which is 0.5 s warm, costs 25–36 s of main
thread CPU inside the window. A plain root costs nothing in the window (11:33), so the hit is
proportional to what is drawn, and the open question is whether every view is ~50× slower or one
thing (the sidebar `List`, SF Symbol labels, trait propagation through UIKit-hosted views) is
pathological. Launches at +0:40 … +1:35 stalled; at +2:00, +3:03 and +3:05 they did not.

Instruments cannot reach the iPad from this Mac over Wi-Fi (`xctrace record --device … ` sits at
"Waiting for device to boot" and times out; `devicectl` works fine), so the in-app sampler is now a
**4 Hz profiler**: during a stall it samples every tick, keeps a histogram, and at the end logs
"stall profile, N samples at 4 Hz — leaf frames: …" and "… leaf < caller: …"; whole stacks are
written at 2 s and every 5 s. Stripped system frames appear as `UIKitCore+0x8c158`; the Mac has the
iPad's exact system symbols (iPad8,11 26.6.2), and `Scripts/symbolicate-stall.sh <reel.log>` resolves
every such frame in the log with `atos --offset` (checked: `UIKitCore+0x8c158` → `UIApplicationMain +
332`). The log queue is now user-initiated QoS so lines survive a kill on a busy device. Next: one
more reboot with Reel launched at about +0:45, then `Scripts/symbolicate-stall.sh` on the pulled log
says, by UIKit function name, what the main thread spends 25 s on inside the boot window.

**16 Nov 12:06, the profile (launch at +1:28): flat.** 14.8 s stall, CPU 13.5 s user, 0.0 kernel,
53 samples at 4 Hz, and the hottest leaf frame has **4 hits**: `AttributeGraph+0xc6bc` ×4,
`CoreFoundation+0x15f8` ×3, `AttributeGraph+0x4740` ×2, then singletons across UIKitCore,
QuartzCore, libswiftCore (`swift_isEscapingClosureAtFileLocation`, `swift_beginAccess`),
`__CFStringHash`. Symbolicated callers are the ordinary render path (`_UIHostingView.layoutSubviews`,
`CA::Layer::layout_and_display_if_needed`, `_UIUpdateSequenceRunNext`). No hot loop, no hot
function: ordinary SwiftUI render code executing uniformly slowly, in user mode, on a core we held
91 % of the time. That is the signature of a **slow processor**, not slow code. The watch thread now
times a fixed spin loop at each stack sample ("calibration at Ns: fixed spin took N ms; thermal …,
low power …, N of N cores active"); the same spin warm on this iPad (Debug build) is about 0.7 s (7.1 s measured with the first, ten-times-longer loop)
in the log just before the next reboot. Spin 20–50× slower in the window → the CPU is the cause
(frequency capped or an efficiency core while iPadOS does its post-boot work), and Reel's only
lever is to draw less in those two minutes. Spin normal → the slowness is specific to our main
thread and the next look is at its scheduling (QoS, core affinity) in the window.

**16 Nov 12:33, both stories fall.** Two reboots were lost (the iPad rejoins the other Wi-Fi at boot
and the Mac cannot reach it), then Paul opened Reel by hand at **+3:27 after a reboot and it stalled
20.6 s** (CPU 19.3 s user, 0.0 kernel) while the watch thread's spin ran at the warm **0.75 s** every
time, thermal nominal, 8 of 8 cores. So: not a boot window, not a slow processor. Nor the first
launch after an install (11:30, 11:40, 12:10 and 12:29 were first launches and clean). The five
whole stacks, fully symbolicated (`Scripts/symbolicate-stall.sh`, or frame by frame with `atos
--offset`), all sit under one `_UIHostingView.layoutSubviews` → `ViewGraphRootValueUpdater.render`
and show SwiftUI doing a *lot* of ordinary work: `ForEachList.Init.updateValue()` (a `ForEach`
being rebuilt), `RendererEffectDisplayList.value`, `GraphHost.startTransactionUpdate` →
`propagate_dirty`, and twice `Update.dispatchActions` → `UIView _updateTraitsIfNeeded` →
`_wrappedProcessTraitChanges` **recursing 10–13 levels** of UIKit views → `UITraitCollection
isEqual` / `_createTraitTokenSetForChangesFromTraitCollection`. A UIKit hierarchy that deep and
that wide inside Home's hosting view points at the lazy shelves having built **every card** as a
live view (each `PosterCard` carries a `NavigationLink`/`Button` and a UIKit context-menu
interaction), which a horizontal `LazyHStack` does when its `ScrollView` is laid out at an
unbounded or placeholder width at the first frame — plausibly what differs between a launch that
goes straight to a sized window and one whose scene is sized late. Instruments for that: the busy
line now counts `poster card body` and `shelf row body` (thousands → every card was built), and
RootView logs "root size W×H, size class …" at the first frame and on every change (a 0×0 or
screen-sized first layout followed by the real window size would be the smoking gun).

**16 Nov 12:43 — the sampler froze the app, and the size theory is weak.** Paul opened Reel 44 s
after a reboot: root size **1366×967, regular, from the first frame** (no placeholder size), 3 card
and 4 row bodies before activation, then the stall began at "scene active" with the spin at 0.8 s.
At 10 s the log stops dead: no more samples, no end line, none of the scan/source lines that always
follow a launch; the process was later relaunched by iOS in the background (12:47:42, root 1024×1309,
portrait). The whole process had frozen, watch thread included. Cause: the sampler **allocated while
the main thread was suspended** (`addresses.append` between `thread_suspend` and `thread_resume`); a
main thread suspended inside malloc holds the allocator lock, the watch thread then waits for it
forever, and nothing ever resumes the main thread. 4 Hz sampling made the race likely; it also
explains the lines "lost to the kill" at 11:43. Fixed: frames go into a preallocated 64-slot buffer
and nothing between suspend and resume allocates, logs or locks. So the first-frame size is correct
and the "unbounded lazy shelf" reading has no support yet; the card-body counts at the end of a stall
are still the thing to read, on the next (now safe) run. Paul described this startup as "much
faster", which may be the 10 s before the freeze rather than a change in the stall itself.

**16 Nov 18:09 — a full stall with the safe sampler: zero Reel bodies, UIKit trait propagation.**
Reboot at 18:08:55, Reel opened at 18:09:35, root 1366×967 regular from the first frame, then a
**35.9 s stall (34.6 s user CPU, 113 samples, spin 0.75–0.8 s throughout, thermal nominal, 8 cores)**.
The busy line has **no "during it:" clause**: not one Root, Home, shelf-row or poster-card body ran
during the stall, so "lazy shelves build every card" is dead along with the size theory. Every
whole-stack sample is one `_UIHostingView.layoutSubviews` commit; symbolicated (`Scripts/symbolicate-stall.sh`)
the recurring frames are `-[UIView _wrappedProcessTraitChanges:withBehavior:]` 8–13 levels deep under
`_processChangesFromOldTraits:toCurrentTraits:` and `_updateTraitsIfNeededWithBehavior:`, reached
from `SwiftUI.Update.dispatchActions` inside `ViewGraphRootValueUpdater.render`; one sample sits in
`_UITraitCollectionUserInterfaceRenderingModeDidChange` ← `-[UITraitCollection _setNSIntegerValue:forTraitToken:]`,
one in `_UISplitViewControllerAdaptiveImpl _traitCollectionForChildEnvironment:`, one resolving a
SwiftUI `Color` through `UIKitPlatformColorDefinition.resolvedHDRColor` from `PlatformViewChild.updateValue`,
others in `AG::Graph::propagate_dirty` / `GraphHost.flushTransactions` / `setRootView`. Faults +21108
against page-ins +930: the commit allocates roughly 80 MB of zero-filled pages. Reading: UIKit is
re-propagating trait collections (the rendering-mode trait among them) down the hosting view
hierarchy over and over, and SwiftUI re-resolves platform colours each time, with no Reel body in
the loop. Next: the level-3 root test (`NavigationStack { HomeView() }`, no split view) is **armed**
for the next launch; if it stalls the cost is in Home's UIKit-backed content, if not it is the
split view / sidebar, and level 2 (split view with an empty detail) decides.

**16 Nov 22:16 — the level-3 launch (Home in a NavigationStack, no split view) was clean**: ready
0.22 s, first frame 0.48 s, no stall lines at all. Whether a reboot preceded it is unconfirmed (the
previous process logged until 22:10:21; a new one started at 22:16:06). If Paul did reboot, the
split view / sidebar is where the 36 s goes and level 2 confirms it; if not, the run says nothing.

**17 Nov 07:43 — Reel exited during playback with no crash report.** The log stops at 07:43:46
mid-play (S05E15 at 32 s); `systemCrashLogs` holds no Reel `.ips`, no JetsamEvent and no stackshot
for that time, ten minutes later. The two minutes before: three episode switches in 90 s (E15 → E14
→ E15, each "rebuilt VLC player: previous input still stopping"), and **two intro searches running
at once** (E15's started 07:41:53, E14's 07:41:58), each a software x265 1080p 10-bit grab player at
6× over SMB whose passes "gave up" after 20–33 s and restarted "from there" (9 grabs in two minutes,
700–840 frames delivered each). `ShowMarkers.locateIntro` never checks that its episode is still
the one playing, so a search for a superseded episode runs its full budget (2 stretches × 4 passes)
alongside the new one's. **Fixed (17 Nov):** `FrameGrabber.cancel()` ends the run in flight at once
(its `frames` call returns what it has) and closes the player; `ShowMarkers` keeps the grab of each
search in `activeSearches` and `cancelIntroSearches(except:)` cancels every other episode's, logged
as "intro search in … cancelled: another episode is playing"; `PlayerCoordinator` calls it just
before `engine.load`. A cancelled episode is not marked searched, so its search runs when it next
plays. Whether this was the 07:43 exit's cause is unproven (no report exists); the next such exit
should be checked the same way (`devicectl device copy from --domain-type systemCrashLogs`).

**17 Nov 12:53 — the normal root stalled again: 30.3 s (29.1 s user CPU), 97 samples**, the same
flat AttributeGraph profile, during it Home body ×2, Root body ×1, shelf row body ×4 and no card.
Build 301a069 (intro-search cancel) changes nothing here, as expected. Level 2 (split view and
sidebar, empty detail) is armed for the next launch: a stall there puts the cost in the split view
and its sidebar (the stacks' `_vibrancy` and "rendering mode did change" traits fit the sidebar's
glass material); a clean one, with level 3 clean too, leaves the pairing of split view and Home.

**17 Nov 12:58 — level 2 after a confirmed reboot (12:57) was clean**: ready 0.19 s, first frame
0.48 s, no stall (the 20 s "stall" at 12:59 has 0.1 s CPU and a 21 s spin: the process suspended in
the background, not a stall). So the sidebar and split view alone cost nothing; the detail's
hierarchy is what the work walks. Symbolicated leaf frames across the profiles: `AG::Graph::UpdateStack::update/push`,
`AG::Graph::propagate_dirty`, `swift_getGenericMetadata` cache lookups, `-[UITraitCollection _valueForTraitWithMetadata:]`,
`_createTraitTokenSetForChangesFromTraitCollection:` — SwiftUI graph work plus UIKit trait reads,
nothing of Reel's. The stall starts in the same second as "scene active" and nothing Reel logs
falls inside it: the commit it sits in is the one activation causes, when UIKit flips the
active-appearance trait on every view under the hosting view and SwiftUI re-resolves platform
colours (`PlatformViewChild.updateValue` → `Color.resolve`) — exactly the frames seen. The same
flip on a warm launch or an app-switcher round trip costs 1–2 s, so a per-boot factor of ~30
remains unexplained. Two one-shot tests queued: **level 3 armed** (Home in a NavigationStack, no
split view; the 22:16 run of it was clean but its reboot is unconfirmed) and **level 5** added
(`RootView.noContextMenus`: the normal root with the poster cards' `.contextMenu` left off, one
UIKit interaction view fewer per card; arm with `reel://debug-plain-root?level=5`).

**17 Nov 13:11 — level 3 after a confirmed reboot (13:10) was clean**: ready 0.21 s, first frame
0.49 s, scene active at +0.7 s, no stall before Paul put it in the background 6 s later. The bisect
now reads: a plain label (1), the split view with its sidebar and an empty detail (2) and Home in a
NavigationStack without the split view (3) all launch instantly after a reboot; Home inside the
split view's detail stack (the normal root) takes 30–36 s. The pairing is the fault, not either
half. Level 5 (normal root, cards without `.contextMenu`) is armed for the next launch; if it is
also slow, level 4 (split view with `NavigationStack { Text }`) tells whether the detail stack
itself is enough.

**17 Nov 13:21 — level 5 after a confirmed reboot (13:19): 7.8 s instead of 30–36 s.** The normal
root with the poster cards' `.contextMenu` (and the modifier's `.sheet`) left off: ready 0.47 s,
first frame 0.57 s, then a 7.8 s stall (6.5 s user CPU, spin 1.05–1.1 s, 16 samples; during it
Home body ×1, Root body ×1, poster card body ×15, shelf row ×2) in the activation commit, the
same AttributeGraph / `ViewRendererHost.performExternalUpdate` frames. So each card's context-menu
interaction is roughly three quarters of the post-reboot cost and something else per card or per
shelf is the rest. Product direction: keep UIKit interaction views out of the activation commit
(attach the menus a moment after activation, or replace the per-card menu with one shared
presentation), then measure the remainder the same way.

**Fix in hand (13:26): the poster context menus attach 2.5 s after RootView appears** (`RootView.interactionsReady`
→ environment `\.interactionsReady`; `ItemContextMenu` is a no-op until then; the log says "launch:
card context menus attached"). Warm launch: active at +0.7 s, menus at +2.5 s, no stall. To verify
after a reboot: the activation commit should be the 8 s of level 5 or less, and the commit that
attaches the menus should be short; if that second commit is the 20 s instead, the cost is the
menus' creation, not the activation walk, and the per-card menu has to go (one shared presentation
from a long press).

**17 Nov 13:31 — the deferred-menu build after a confirmed reboot: the app froze again at the
10 s sample** and iOS relaunched it in the background at 13:36:50, exactly the 12:43 pattern. The
stall was under way (8.4 s CPU at 10 s, the same frames), so the deferral has not been measured. The
freeze is the sampler once more: the suspend-to-resume stretch was still Swift, and in a Debug
build `withUnsafeMutablePointer(to: &pair)` on a `(UInt64, UInt64)` and the `arm_thread_state64_t`
rebinding go through unspecialised generic entry points that fetch type metadata, which takes the
Swift runtime's metadata lock, the very lock the main thread holds in `swift_getGenericMetadata`
throughout these stalls. **Fixed: the walk is now C** (`Packages/ReelKit/Sources/ReelStackSample`,
`reel_sample_thread`), with no Swift between `thread_suspend` and `thread_resume`. Both freezes
were Debug builds; Release specialises those calls, which is why the 11:26 Release run sampled
without freezing.

**17 Nov 14:11 — deferred menus after a confirmed reboot: the activation commit is clean, the menu
commit is the stall; the "freezes" were suspensions.** First frame 0.48 s, no stall at activation
(the first post-reboot launch ever to activate cleanly), "card context menus attached" at +2.6 s,
and *that* commit stalled: 8.8 s CPU by its 10 s sample, the same `_UIHostingView`, AttributeGraph
and `swift_getGenericMetadata` frames. So the cost is **creating** the per-card context-menu hosting
views, not the activation walk over them. Paul saw white, the splash, then Home "quickly" and
called it good: Home is on screen while the menu commit runs, so the visible symptom is gone, but
the main thread is still blocked for 10 s or more about three seconds into every post-reboot launch.
The log again stopped at the 10 s sample, with the process alive (pid 441), no report, a command
file unconsumed and a foreground-launch request having no effect: Paul had left Reel (and the iPad
was likely locked), so iOS suspended the process mid-stall. The same explains 12:43 and 13:31 (both
followed by a background relaunch for a push); the two sampler rewrites were not the cause, though
the C walk stays as the safer design. When Reel next comes to the foreground the stall finishes and
the busy line appears with the full duration. Next: no per-card UIKit interaction at all, one shared
presentation from a long press (`onLongPressGesture` + a single `confirmationDialog`/menu at the
shelf), then measure the menu commit again; and the ×30 post-reboot factor on this commit is still
unexplained.

**Fix (17 Nov, afternoon): no per-card context menu.** A long press on a poster
(`itemLongPress`, a high-priority `LongPressGesture` so the card's link does not fire on release)
sets the shelf's or grid's `menuItem`, and the card's `itemActionsDialog` (a `confirmationDialog`
anchored to the card, with the old menu's actions, collections flattened to one line each) shows
while `menuItem` is its item; the artwork sheet is one per shelf. No UIKit interaction exists per
card. Checked on the simulator: tap navigates, long press opens the dialog on the card. The 2.5 s
deferral, the `interactionsReady` environment value and root test level 5 are gone. To verify after
a reboot: no stall at activation and none later (there is no menu commit any more); the per-card
`confirmationDialog` modifier is assumed cheap, and if a stall remains it is the first suspect, then
the 7.8 s of level 5 (the rest of Home's hierarchy).

**17 Nov 15:09 — a per-card `confirmationDialog` costs the same as a per-card context menu.** With
the dialog modifier on every card, the first launch after a reboot stalled 22.9 s (21.8 s user CPU,
71 samples, no Reel body) at activation, the same frames. So presentation modifiers per element
are UIKit-backed at launch too. **Now: one dialog per shelf or grid.** Each card publishes its
bounds through `anchorPreference` (`ItemAnchorKey`, pure SwiftUI); the shelf's `ItemActionsDialog`
reads them with `overlayPreferenceValue`, places an invisible, non-hit-testable stand-in over the
pressed card and presents the `confirmationDialog` from that, so it anchors to the card. The only
per-card addition is the high-priority `LongPressGesture`. Checked on the simulator: long press
opens the dialog on the card, tap navigates. If the next post-reboot launch still stalls, the
gesture is the last per-card suspect and would move to the shelf.

**17 Nov 15:3x — the gesture cannot move to the shelf.** A press-then-drag sequence
(`LongPressGesture.sequenced(before: DragGesture(minimumDistance: 0))`) on the shelf, whether high
priority or simultaneous, held the scroll view's pan for every drag that began on a card (checked on
the iPhone simulator against a build with the gesture switched off, which scrolled). A plain
`LongPressGesture` per card, high priority, scrolls fine (it fails within ten points of movement),
opens the shelf's one dialog anchored to the card, and keeps the card's link from firing on
release. That is the shipped shape: per card one `LongPressGesture` + an `anchorPreference`, per
shelf one `confirmationDialog` + one artwork sheet. Whether a plain gesture per card costs anything
at launch is the open question for the next post-reboot measurement (level 5, with nothing per
card, was 7.8 s).

If it happens again: the splash names the step, and the log's "launch:" lines say how long it
sat there and whether the process was starved. If the screen is white with no splash and no "launch:" lines at all, the block is
before `ReelApp.init` (dyld loading VLCKit's frameworks is the remaining candidate) and the next
step is a sysdiagnose from the iPad while the white screen is up.

## Play after the iPad slept dropped back to Home (15 Nov 2026)

Twice in one afternoon on the iPad: Reel paused in the player, the iPad slept for 40–50 minutes,
Paul woke it and tapped play, and the app fell back to the Home screen. No crash. The Reel log
reads "paused for 3040s; seeking to 4238s", "status playing", then "dismissed at 4238s of 5915s",
"status idle", "status ended at 0s". The VLC log for the same second: `smb2_service: POLLHUP,
socket error`, `STATUS_CANCELLED` on the first read, "end of stream", both tracks disabled
"(eof?)", input destroyed. The SMB socket had died during the sleep and libvlc reported the read
failure as the stream running out.

In the engine that arrives as VLC's `.stopping` state. The "a stop well short of the end is the
stream dying, reconnect" check in `handleStateChange` only looked at `.stopped`, so `.stopping`
after playback began went straight to `.ended`; the coordinator's status watcher (a `@Published`
sink, so it fires before the status assignment is logged, which is why "dismissed" is printed
before "status ended") marked the film watched and dismissed the player. Now both `.stopping`
and `.stopped` more than 20 s before the end log "stream stopping Ns before the end" and
`reconnect()` reopens the stream at the position.

Reconnects are now **three tries over at least 30 s** (`VLCPlaybackEngine.reconnectTries`,
`reconnectDelays` 10 s and 20 s): the first at once, and when a try cannot open (VLC's `.error`
before anything played, or the 20 s open watchdog) `reconnectAgainLater` waits and tries again at
the same position, logged "reconnect 2/3 could not open; trying again in 20s"; the open watchdog
of a failed try is cancelled so it does not reload on top. Only after the third does the error
card come ("Lost the connection to host and couldn't get it back", Retry / Back), not a drop to
Home. While it runs the engine publishes `reconnecting` (the attempt number) and the player shows
a pill above the scrubber, "Reconnecting to DiskStation (smb://192.168.1.124) · try 2 of 3"
(`PlayerCoordinator.sourceLabel`: the file's source name and the URL's scheme and host).
Checked on the simulator by killing the WebDAV server under a playing clip: with the server back
within 30 s the third try plays on from the position; with it kept down, "gave up reconnecting
to 127.0.0.1 after 3 tries" at 31 s and the card. Not yet seen on the iPad after a real sleep.
Code: VLCPlaybackEngine `handleStateChange`, `reconnect`, `reconnectAgainLater`, `startOpenWatchdog`.

Simulator corpus note: the scratchpad had been wiped, so the clips and the throttle proxy from
"Screenshots (31 Oct 2026)" were remade for this: two 40 s `ffmpeg` clips (E01 is a 1280×720
random-noise encode of ~550 MB so VLC cannot read it all up front; E02 the tiny test pattern)
under `scratchpad/clip/TV/Test Show/Season 1/`, served straight by `wsgidav` on 127.0.0.1:8080
from a fresh venv (`pip install wsgidav cheroot`), no proxy.

## Intro search and credits on Atlantis S3 (5 Nov 2026)

What the iPad log showed: no intro search had ever finished since 2 Nov (never an "intro found" or
"intro not found" line), every one ended in "grab from 13s gave up" and then silence, so
`ShowMarkers.isSearchingIntro` stayed true, the scrub thumbnails waited their full five minutes
and `confirmCredits` its ten. And the credits in S3 came "by chapter at 2396s": those files end
with an unnamed 220 s chapter (the last scene plus the credits) that the shape rule took for the
credits, so Up Next came up three and a half minutes early.

Reproduced on the simulator with a throttling proxy (`scratchpad/throttle-proxy.py`, 1 MB/s,
SIGSTOP to freeze it) in front of the WebDAV corpus and the `reel://debug-grab-current` hook: when
the input stalls, libvlc's clock runs on at the playback rate and the memory output shows the
**last picture again and again with a later time each** ("60 frames in 9.5 s" of one picture; the
iPad's "113 frames delivered, 294 kept"). Twelve times real time over SMB on Wi-Fi is where it
stalled (30–50 Mbit/s files).

Changes:
- `FrameGrabber.frames`: a frame whose fingerprint equals the previous one is a repeat, not a new
  frame: `each` does not see it, it does not keep the stream "alive" (so a stall ends in the
  give-up), and the run reports them (`lastRunRepeats`, logged as "the same picture again").
  `each` now gets every delivered frame once with its real time, not one call per one-second slot
  (at a rate the decoder cannot keep VLC drops to keyframes, and one picture stood for many slots,
  so three slots in a row could never agree on a start). The seek that fixes a dropped start-time
  no longer runs inside libvlc's own display callback. The teardown (`closeSession`) runs on its own
  thread and nothing waits for it: a player stuck in an SMB read held `libvlc_media_player_release`
  and with it the whole search (logged if it takes over 5 s).
- `ShowMarkers`: scans run at 6× (`Grab.scanRate`); `Grab.scan` returns the last real frame time and
  `locateIntro` goes on from there after a stall (up to four passes); a print run that is mostly
  repeats is rejected ("the stream stalled; tried again next play"); the full print run now follows
  a provisional one when the end was marked while it ran (it was silently dropped, which is why
  S02E15's pattern never became usable).
- Credits: `[Chapter].creditsChapter(fileDuration:)` says whether the chapter is named. A named
  credits chapter still wins; a viewer's mark on the show (the season's credits length) now beats
  an unnamed credits-shaped final chapter, which comes third ("credits by the short final chapter").
  Test `testNamedChapterIsTheFilesWordAndAShapedOneAGuess`.

Not yet verified on the iPad: look for "intro found in … (pattern S2)" or "intro not found" within
two minutes of an S3 episode starting, "intro pass stalled at … going on from there" if the share
cannot feed 6×, and "credits by the season's credits length" instead of "by chapter" on S3.
Only one S2 pattern is usable (the others' prints predate `printsVersion` 6 or were provisional);
they are retaken only when those episodes (S02E04/E05/E15) play again.

## PiP across an episode change (5 Nov 2026): Reel owns the window

Asked for: the next episode carrying on in the Picture in Picture window. With VLCKit's own PiP it
could not: VLCKit 4 makes one `AVPictureInPictureController` per libvlc video *display*, the display
is closed when an input ends, the window went with it, and iOS refuses a PiP start from the
background (AVKit's pegasus log never receives it; the same call in the foreground succeeds; tried
on a new controller, on the same controller after a programmatic stop, and with the same
`VLCMediaPlayer` handed the next media).

Now (`ReelPictureInPicture` in Playback): Reel makes **one** `AVPictureInPictureController` for the
life of the engine, over the `AVSampleBufferDisplayLayer` VLCKit inserts into the drawable
(`VLCDrawableView` no longer conforms to `VLCPictureInPictureDrawable`, so VLCKit makes no
controller of its own). Every load puts a new display view into the drawable; the engine finds the
newest layer (`attachDisplayLayerIfNeeded`: on drawable layout, on `.playing`, and on the time ticks
for 30 s after a load, because UIKit lays nothing out in the background) and hands it over as the
controller's `contentSource`. An open window carries on with the new layer: on the iPad simulator
the log reads "PiP: new display layer handed to the window (active true)" and pegasus shows no
`_stopPictureInPictureAnimated` at the change. The window's play/pause/skip/timeline come through
`AVPictureInPictureSampleBufferPlaybackDelegate`, answered from a snapshot the engine refreshes on
status, ticks and length (`pip.update`); the timeline is placed so the layer timebase's "now" falls
at the current position. `engine.stop()` (dismiss) closes the window; a load uses
`stop(forReload:)` and keeps it. `canStartPictureInPictureAutomaticallyFromInline` is on, so Home
still starts PiP by itself. Returning to the app stops PiP as before.

Not verified on a device: that the window really shows the new episode's frames (the simulator's
PiP window is always black), the window's own controls, and the timeline position.
