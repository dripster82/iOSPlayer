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
| Distribution | Sideload now → TestFlight later. **Not** App Store yet. |
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
  Views/Sources/        SourcesView (+SourceDetailView, TagSheet, FileBrowserView), AddSourceView
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
- [ ] Scrub thumbnails (`VLCMediaThumbnailer`, 10 s intervals, cached per file).
- [ ] Subtitle style editor (size/colour/position) — VLC `--freetype-*` options at load time.
- [ ] Accessibility pass: VoiceOver labels on player controls, Dynamic Type in grids, reduced motion.
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
