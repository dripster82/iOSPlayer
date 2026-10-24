# Reel — agent handover

You are picking up an iOS/iPadOS media player that has been fully planned, prototyped and written.
It was first authored in a Linux container with no Swift toolchain; on 24 Oct 2026 it was brought to
a **compiling, signed, device-installable** state on Paul's Mac (Xcode 26.6). The device smoke test
(§4) has not been run. Your first job is that smoke test, then continue the phase plan.
Everything you need is in this repo; this document is the map.

Read in this order: this file → `PLAN.md` §6, §10, §11, §12 → `README.md` → the code.

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
README.md               Human-facing build/run instructions.
HANDOVER.md             This file.
project.yml             XcodeGen spec → generates Reel.xcodeproj (gitignored).
Scripts/fetch-vlckit.sh Downloads VideoLAN's MobileVLCKit 3.7.3 xcframework into Packages/ReelKit/Vendor (gitignored).
Scripts/build-device.sh No-iCloud Debug build + install on the paired iPhone; restores Reel.entitlements afterwards (§3).
prototype/index.html    Clickable HTML prototype of every screen. Open in a browser. The app UI follows it.

Reel/                   SwiftUI app target
  App/                  ReelApp (entry, DI), AppSettings (UserDefaults-backed, @Published),
                        PlayerCoordinator (owns the engine, saves progress, Up Next), RootView (tabs vs sidebar)
  Views/Library/        HomeView, TVView (+FilmsView, FavouritesView, CollectionsView in TVView.swift),
                        DetailViews (HeroHeader, FilmDetailView, ShowDetailView, EpisodeRow, FlowLayout),
                        SearchView, NeedsReviewView (+FixMatchView)
  Views/Sources/        SourcesView (+SourceDetailView, TagSheet, FileBrowserView), AddSourceView
  Views/Player/         PlayerView (PlayerView → PlayerContentView, Scrubber, TrackSheet, AirPlayButton, VolumeControl), VLCVideoView
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
                        WebDAVSource (+PropfindParser), SMBSource (#if canImport(AMSMB2)), CredentialStore, SourceDiscovery
  Sources/Playback      PlaybackState (protocol + PlaybackItem/Options), VLCPlaybackEngine, NowPlayingBridge
  Vendor/               MobileVLCKit.xcframework + COPYING.txt (gitignored; binaryTarget declared only when present)
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
Scripts/fetch-vlckit.sh          # MobileVLCKit 3.7.3 → Packages/ReelKit/Vendor (gitignored, ~260 MB)
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
`updatedAt` latest-wins on fetch; `Favourite.deletedAt` is a tombstone. Call `sync.pushPendingChanges()` after writes
(Settings → Sync now does both directions; wiring automatic pushes after each `LibraryStore` write is an open item).

**Settings.** `AppSettings` uses `@Published` + `didSet → UserDefaults`, not `@AppStorage`, because `@AppStorage`
doesn't notify an `ObservableObject`'s subscribers. Keep that pattern.

**Credentials.** `CredentialStore` (KeychainAccess, `afterFirstUnlock`), keyed by source UUID. Never in SwiftData, never in CloudKit, never logged.

---

## 6. Conventions

- Swift 5.10, SwiftUI, structured concurrency. Actors for sources and the scanner; `@MainActor` for stores and coordinators.
- Views read from `LibraryStore` via `@EnvironmentObject`; mutations go through `LibraryStore` methods (they set `pendingSync`).
- No new third-party dependencies without a licence check: permissive (MIT/Apache/BSD) only, and add it to `LicencesView` + PLAN §11.10.
- Match the surrounding comment density: a one-line `///` on public types, comments only where the *why* isn't obvious.
- Commit messages: imperative subject, short body. Push to the branch above. Don't open a PR unless asked.
- UI follows `prototype/index.html`. When you change a screen's behaviour, update the prototype's `QS` notes or the plan if the decision changes.
- Keep `PLAN.md` truthful: when a "Not yet" row in README's status table ships, flip it.

---

## 7. Open items, in phase order (PLAN.md §7)

Phase 2 remainder
- [ ] Wire `sync.pushPendingChanges()` after `LibraryStore` writes (currently only on Settings → Sync now and on enable).
- [x] Background scanning (24 Oct): `LibraryStore.scan` holds a `beginBackgroundTask` assertion so a scan
      survives leaving the app for a few minutes, and `Reel/App/BackgroundScans.swift` schedules a
      `BGProcessingTask` (`uk.co.ketelle.reel.scan`) on every background transition: 60 s later if work is
      pending, else daily. It respects `scanOnCellular` via `NWPathMonitor.isExpensive`. iOS decides when it
      actually runs (usually charging + idle); to force it in the debugger pause the app and run
      `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"uk.co.ketelle.reel.scan"]`.
- [ ] Probe duration/codec/audio/subtitle summaries for `MediaFile` after first play (VLC `media.tracksInformation`) so Film detail's "File" section shows real codecs.
- [ ] Scan: mark files not seen for N scans as missing rather than keeping them forever.

Phase 3
- [ ] OpenSubtitles search/download in the subtitle sheet (confirmation step, daily quota).
- [x] Metadata providers (24 Oct): `MetadataProviders` bundles TMDb + optional TheTVDB + AniDB/Anime-Lists.
      Matcher order for episodes: forced override → AniDB exact title (incl. "2nd Season"/"II"/"Part 2"
      candidates) → Anime-Lists `tmdbtv`/`tmdbseason`/`tmdboffset` → TMDb search (shortening) → TheTVDB
      search bridged to TMDb via remote ids or `/find`. Items are always TMDb-backed. AniDB needs no key
      (daily dump, cached weekly in Caches/metadata/anidb-titles.json; ~2 MB download); TheTVDB needs the
      user's v4 project key (Settings). Toggle "Anime matching" in Settings.
- [ ] Fanart.tv clear logos on the hero.
- [ ] Duplicate detection UI ("2 versions" badge exists via `files.count > 1`; add preferred-version persistence).
- [ ] FTP/SFTP/NFS/DLNA browsing (`UnsupportedSource` placeholders exist; VLC already plays their URLs).
- [ ] Playlists / Up Next queue beyond next-episode.

Phase 4
- [ ] Picture in Picture via `AVSampleBufferDisplayLayer` bridge (risky; cut if it fails — see PLAN §11.11).
- [ ] Scrub thumbnails (`VLCMediaThumbnailer`, 10 s intervals, cached per file).
- [ ] Subtitle style editor (size/colour/position) — VLC `--freetype-*` options at load time.
- [ ] Accessibility pass: VoiceOver labels on player controls, Dynamic Type in grids, reduced motion.
- [ ] App icon.

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
