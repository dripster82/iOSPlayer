# Reel — agent handover

You are picking up an iOS/iPadOS media player that has been fully planned, prototyped and written,
but **never compiled**. The previous agent worked in a Linux container with no Swift toolchain.
Your first job is to get it building in Xcode on this Mac, then run the smoke test, then continue
the phase plan. Everything you need is in this repo; this document is the map.

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
  Reel.entitlements     CloudKit container + keychain group

Packages/ReelKit/       ONE Swift package, SIX modules (keeps Xcode happy, lets pure modules test on any platform)
  Sources/MediaCore     Models.swift, FilenameParser.swift, Classifier.swift, ItemKey.swift, Formatting.swift   — pure Swift
  Sources/Metadata      TMDbClient, TMDbModels, MetadataCache, RateLimiter, ArtworkURL, MatchScorer          — Foundation only
  Sources/MediaSources  MediaSource (protocol, SourceConfig, SourceFactory, withRetries), LocalSource,
                        WebDAVSource (+PropfindParser), SMBSource (#if canImport(AMSMB2)), CredentialStore, SourceDiscovery
  Sources/Playback      PlaybackState (protocol + PlaybackItem/Options), VLCPlaybackEngine, NowPlayingBridge
  Sources/Library       Models (SwiftData @Model classes + LibrarySchema), LibraryScanner (@ModelActor),
                        Matcher, LibraryStore (@MainActor façade), ImageLoader
  Sources/Sync          SyncEngine (CKSyncEngine delegate)
  Tests/MediaCoreTests  FilenameParserTests (13 cases), ClassifierTests (6)
  Tests/MetadataTests   TMDbClientTests (mock transport), MatchScorerTests
```

Module dependency graph: `MediaCore ← Metadata, MediaSources, Playback ← Library (Metadata, MediaSources) ← Sync`. The app links all six.

---

## 3. Getting it to build (your first task)

```sh
cd <repo>
brew install xcodegen            # if missing
xcodegen generate                # → Reel.xcodeproj
open Reel.xcodeproj
```

In Xcode: target **Reel** → Signing & Capabilities → set Team. Let SPM resolve. Build for a **device**
(the simulator can't reach SMB shares on most networks and has no VideoToolbox).

### 3.1 Expected failure points, in order

Work through these; each is a few lines. Don't restructure.

1. **VLCKit package resolution.** `Packages/ReelKit/Package.swift` has
   `.package(url: "https://code.videolan.org/videolan/VLCKit-SPM.git", from: "3.6.0")` with product `VLCKit`.
   This is a best-guess URL. If it fails: find the current official SPM URL/product in the VLCKit README
   (code.videolan.org/videolan/VLCKit) or use the CocoaPods `MobileVLCKit` 3.x as a fallback.
   `VLCPlaybackEngine.swift` already does `#if canImport(VLCKit) import VLCKit #else import MobileVLCKit`.
   Whatever you pick: **dynamic xcframework, LGPL build.** Record the final URL in PLAN.md §11.10.
2. **VLCKit 3.x API names** in `VLCPlaybackEngine.swift`: `audioTrackIndexes/Names`, `videoSubTitlesIndexes/Names`,
   `currentVideoSubTitleDelay`, `currentAudioPlaybackDelay`, `addPlaybackSlave(_:type:enforce:)`,
   `chapterDescriptions(ofTitle:)`, `VLCChapterDescriptionName/TimeOffset/Duration`, `VLCMediaPlayerState` cases.
   Delegate methods take `Notification!`. Fix spellings with Xcode's fix-its.
3. **AMSMB2 3.x async API** in `SMBSource.swift`: `SMB2Manager(url:credential:)`, `connectShare(name:)`,
   `contentsOfDirectory(atPath:)`, `attributesOfItem(atPath:)`, `disconnectShare()`. Check attribute keys if listings are empty.
4. **SwiftData `#Predicate`** in `LibraryStore.swift`, `LibraryScanner.swift`, `Matcher.swift`, `SyncEngine.swift`.
   If the macro rejects an expression, fetch broader and filter in Swift.
5. **`CKSyncEngine` delegate** in `SyncEngine.swift`: `handleEvent` and `nextRecordZoneChangeBatch` are `nonisolated`
   and hop to `MainActor`. `RecordZoneChangeBatch(pendingChanges:recordProvider:)` is `async`.
6. **Concurrency diagnostics.** `SWIFT_STRICT_CONCURRENCY = minimal` in `project.yml` deliberately. Don't raise it until it builds.
7. **Small Swift-isms** the author couldn't compile-check: `switch` expressions, `if let x, cond` shorthand, `Layout` protocol
   (`FlowLayout`), `UnevenRoundedRectangle`, `ContentUnavailableView` — all iOS 17 / Swift 5.9+. Should be fine.
8. **`extension String: Identifiable`** in `SourcesView.swift` (used for `.sheet(item:)` with a folder path).
   If it collides with anything, replace with a tiny `struct FolderPath: Identifiable`.

### 3.2 Run the unit tests

```sh
cd Packages/ReelKit && swift test --filter 'MediaCoreTests|MetadataTests'
```
or Product → Test in Xcode. They must all pass before any device testing; they define the parser's contract.

---

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
- [ ] `BGAppRefreshTask` daily scan (PLAN §11.3). Register in `ReelApp`, respect `scanOnCellular`.
- [ ] Probe duration/codec/audio/subtitle summaries for `MediaFile` after first play (VLC `media.tracksInformation`) so Film detail's "File" section shows real codecs.
- [ ] Scan: mark files not seen for N scans as missing rather than keeping them forever.

Phase 3
- [ ] OpenSubtitles search/download in the subtitle sheet (confirmation step, daily quota).
- [ ] TheTVDB episode ordering fallback; Fanart.tv clear logos on the hero.
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
