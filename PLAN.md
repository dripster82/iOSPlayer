# iOS Media Player: Product Plan

A media player for iPhone and iPad that plays nearly any video file (including MKV), reads from network shares and local storage, organises the library into TV and Films, and enriches it with artwork and metadata from public sources. The reference point is Infuse.

This document covers scope, features, and UI flow. It does not cover implementation details beyond the technical decisions that shape the features.

---

## 1. Goals and non-goals

### Goals
- Play ~99% of real-world video files without transcoding by the user: MKV, MP4, M4V, AVI, TS/M2TS, WebM, WMV, FLV, and common subtitle formats.
- Stream from network sources (SMB, NFS, WebDAV, FTP/SFTP, DLNA/UPnP) and from local storage (Files app, USB drives, iCloud Drive).
- Automatically sort media into **TV Shows** and **Films**, with posters, backdrops, synopses, cast, and episode data.
- Feel native on iOS and iPadOS: fast, gesture-driven, correct on both phone and iPad layouts.
- Keep the user's library in order without them having to rename files.

### Non-goals (v1)
- Not a media server (no Plex/Jellyfin server hosting).
- No DRM-protected content (FairPlay, Widevine, etc.). Legal sources only.
- No live TV or EPG in v1.
- No downloading of torrents or any content acquisition.
- No Android, tvOS, macOS, or web client in v1.

---

## 2. Target users and key scenarios

| Persona | Scenario |
|---|---|
| Home media owner | Has a NAS with a film and TV library. Wants it browsable on the phone, with the same watch state on iPad. |
| Collector | Has MKV rips with multiple audio and subtitle tracks. Expects every track to play and be selectable. |
| Casual viewer | Plugs in a USB drive or AirDrops a file and expects it to just play. |
| Binge watcher | Wants to resume a series where they left off, with next episode queued. |

---

## 3. Feature set

### 3.1 Playback engine (core)

This is the hardest requirement. Apple's `AVPlayer` does not support MKV, and many codecs and containers in a typical library need a broader decoder.

**Recommended approach:** a hybrid engine.
- **Primary: FFmpeg-based demux and decode** (via a maintained build such as MPVKit or VLCKit). Covers MKV, AVI, WMV, FLV, TS, and most codecs (HEVC, H.264, VP9, AV1, MPEG-2/4, VC-1, and common audio: AC3, E-AC3, DTS, TrueHD, FLAC, Opus, Vorbis, AAC).
- **Hardware decode where possible** via VideoToolbox, with a software fallback.
- **Secondary: `AVPlayer` path** for MP4/M4V/MOV with HLS-friendly codecs where it gives better battery life and native PiP and AirPlay behaviour. Optional, can be cut from v1 if it adds complexity.

Playback capabilities:
- Play, pause, seek (tap, drag, double-tap skip), variable speed (0.5x to 2x).
- Multiple audio tracks, switchable during playback. Language and default flags respected.
- Embedded and external subtitles: SRT, ASS/SSA (styled), VobSub, PGS (image-based), WebVTT, plain text.
- Subtitle styling: font, size, colour, outline, position, delay adjustment.
- Audio delay adjustment and audio passthrough option where the output device supports it.
- HDR10, HLG, and Dolby Vision (where decodable; fall back to HDR10 base layer otherwise).
- Chapters with chapter list and skip-intro support where chapter metadata is present.
- Resume playback at the last position across devices (see 3.6).
- Picture-in-Picture and background audio.
- AirPlay output.
- Lock-screen and Control Centre controls, Now Playing info.
- Brightness and volume swipe gestures; long-press for speed boost.

### 3.2 Sources and file access

| Source | Protocol | Notes |
|---|---|---|
| SMB / Windows shares | SMB 2/3 | Most common for NAS. Needs credentials per share. |
| NFS | NFS v3/v4 | Mainly for Linux NAS. Lower priority than SMB. |
| WebDAV | HTTP(S) | Covers Synology, Nextcloud, and many cloud drives. |
| FTP / SFTP | FTP, SSH | Basic support. Useful for seedboxes and older NAS. |
| DLNA / UPnP | Discovery + HTTP | Read-only browse and play from media servers on the LAN. |
| Local | Files app, USB, iCloud Drive | Via the document picker and File Provider. Copy-free where possible. |
| Photos | Photos library | Only for short clips and personal video. Not a primary source. |

Source management:
- Add, edit, remove sources. Credentials stored in the iOS Keychain.
- Auto-discovery of SMB and DLNA hosts on the LAN (Bonjour and SSDP), with manual entry as fallback.
- Per-source connection status and last-scan time.
- Background refresh of library indexes where iOS allows.
- Offline behaviour: cached metadata and artwork remain visible when a source is unreachable. Playback shows a clear error.

### 3.3 Library and organisation

**Automatic classification**
- Filename and folder parsing decides whether an item is a TV episode or a film. Examples handled: `Show.Name.S02E05.1080p.mkv`, `Show Name/Season 2/05 - Title.mkv`, `Film Name (2019).mkv`, `Film.Name.2019.BluRay.x265.mkv`.
- Folder hints are weighted: `TV/`, `Series/`, `Films/`, `Movies/` in the path.
- Ambiguous items go to a **Needs Review** queue rather than being guessed.

**Matching and metadata**
- Primary metadata provider: TMDb (films, TV shows, seasons, episodes, cast, crew, ratings, artwork).
- Optional secondary providers: TheTVDB for episode ordering, Fanart.tv for extra artwork, OpenSubtitles for external subtitles.
- Manual match: search by title and year, pick the correct entry, and save the choice.
- Local overrides stored in the app so the source files are never modified.

**Imagery from public sources**
- Posters, backdrops, logos, and episode stills downloaded and cached on device.
- Cache size limit with user control, and a "clear artwork cache" action.
- Attribution screen listing data providers as their terms require.

**Library views**
- Home: Continue Watching, Recently Added, Next Up (TV), Unwatched Films.
- TV Shows: grid of shows, each opens to seasons, then episodes.
- Films: grid of films with sort (title, year, date added, rating, runtime) and filter (genre, year, unwatched).
- Collections: user-created groupings (e.g. "Christmas", "Sci-Fi Marathons").
- Search across title, cast, genre, and year, with voice-free keyboard search.

**Library maintenance**
- Mark as watched/unwatched, individually or by season.
- Hide items, or hide whole sources from the library.
- Duplicate detection: same title and year across sources, with a choice of preferred copy.
- Show all unmatched files in one place for batch fixing.

### 3.4 Subtitles

- Auto-select subtitles by preferred language list, with forced subtitles shown when audio matches the forced language.
- Search and download external subtitles (OpenSubtitles) when none exist, with a confirmation step.
- Subtitle sync: nudge timing in 0.1 s steps.
- Remember the subtitle choice per show or per film.

### 3.5 Watch state and history

- Per-item progress, watched flag, and last-played date.
- Resume prompt: "Resume at 42:10 or start over?".
- Watch history screen with a clear-history option.
- Next-episode auto-play with countdown and a "Stop after this" option.
- Watch state syncs across the user's own devices (see 3.6). Conflicts resolved by most recent write.
- **Favourites:** mark any show, film, or episode as a favourite. A Favourites row on Home and a Favourites filter in TV and Films. Syncs via iCloud like watch state.

### 3.6 Accounts, sync, and privacy

- No account required for local use.
- iCloud sync (CloudKit) of watch state, resume positions, favourites, and library overrides across the user's iPhone and iPad. No separate sign-in: it uses the device's Apple ID. If iCloud is unavailable, the app works locally and syncs later. Design in section 10.4.
- Credentials for sources never leave the device. They are not synced unless the user opts in and the keys go through iCloud Keychain.
- No analytics by default. Opt-in crash reporting only.
- Clear privacy policy stating which metadata lookups are sent to TMDb and OpenSubtitles (titles and file hashes or names, not files).

### 3.7 Playlists and queue

- Up Next queue, drag to reorder.
- Playlists of mixed films and episodes.
- Play all from a folder or season.
- Shuffle and repeat modes.

### 3.8 Settings

- Playback: default audio and subtitle languages, hardware decoding on or off, HDR handling, speed presets, skip intervals.
- Subtitles: default styling and presets.
- Library: metadata language and region, artwork quality, scan schedule, folder rules.
- Sources: manage sources, discovery, timeouts, and retry behaviour.
- Storage: artwork cache, metadata cache, clear all.
- Appearance: light/dark/system, accent colour, app icon choice.
- About: version, licences (including FFmpeg/LGPL notices), data-provider attribution.

---

## 4. UI flow

### 4.1 Navigation structure

**iPhone: tab bar**
1. **Home**
2. **TV**
3. **Films**
4. **Sources**
5. **Search** (or a search icon in the top bar, to free a tab)

Settings sits behind a gear icon in Home and Sources. Player is a full-screen modal over any tab.

**iPad: sidebar**
- Sidebar with Home, TV Shows, Films, Collections, Playlists, Sources, Search, Settings.
- Content area uses a split view: grid on the left, detail on the right when a show or film is selected.
- Player opens full-screen or in a floating window with PiP.

### 4.2 First-run flow

1. **Welcome**: one-line value statement, "Get started" button.
2. **Add a source**: choose Local, Network (SMB, WebDAV, NFS, FTP/SFTP, DLNA), or Skip for now.
   - Network path shows auto-discovered devices, then a manual form.
   - Credentials form with "Save to Keychain" toggle, and a Test Connection button.
3. **Pick folders**: browse the source, tick the folders that hold films and TV. Each folder can be tagged as Films, TV, or Mixed.
4. **Scanning**: progress bar with count, "You can keep using the app while this runs."
5. **Metadata matching**: prompt to confirm matches for the first batch of items, with a shortcut to skip.
6. **Done**: lands on Home with the library populated.

### 4.3 Browse flow

**Home**
- Continue Watching (horizontal row, with progress bar on each poster).
- Next Up (TV episodes queued after the last watched).
- Recently Added.
- Source status strip at the bottom if any source is offline.

**TV Shows**
1. Grid of show posters with unwatched-episode badge.
2. Tap a show: detail screen with backdrop, synopsis, rating, cast, and season picker.
3. Tap a season: episode list with still, title, runtime, progress bar, watched tick.
4. Tap an episode: plays directly, or opens the detail sheet if the user long-presses.

**Films**
1. Grid of posters, with sort and filter controls in the top bar.
2. Tap a film: detail screen with backdrop, synopsis, cast, file info (resolution, codec, audio tracks, subtitle tracks, size), and a Play button.
3. If multiple copies exist, a "Versions" row lets the user pick one.

**Sources**
1. List of sources with status (online, offline, syncing).
2. Tap a source: folder tree. Each folder shows its tag (Films, TV, Mixed, or none).
3. Long-press a folder to change its tag or to exclude it.
4. Browsing a source directly (without the library) is always available: a plain file view with Play.

**Search**
- Single search field, results grouped as Shows, Films, Episodes, People, Files not in library.
- Recent searches and filter chips (Films, TV, Unwatched).

### 4.4 Playback flow

1. Tap Play. Player opens with a short fade and the artwork as background while buffering.
2. **Controls overlay** (auto-hide after 3 s):
   - Top: back, title, episode code, AirPlay, subtitles, audio, more.
   - Centre: previous, play/pause, next.
   - Bottom: scrub bar with thumbnail preview, time remaining, speed, chapters, lock.
3. **Gestures**
   - Single tap: show or hide controls.
   - Double tap left or right: skip back or forward 10 s (configurable).
   - Horizontal drag: scrub, with preview.
   - Vertical drag, left half: brightness. Right half: volume.
   - Long press: 2x speed while held.
   - Pinch: fill, fit, or zoom.
4. **Track sheets**
   - Audio: list of tracks with language, codec, channels. Selecting one switches without restarting.
   - Subtitles: list with Off, embedded tracks, external, and "Search online". Style and delay controls at the bottom.
5. **Chapters**: a sheet listing chapters with thumbnails. Skip-intro button appears when chapter metadata marks an intro.
6. **Up Next**: at the end of an episode, a card appears for 15 s with the next episode, Play Now, and Stop.
7. **Errors**: a clear card ("Source unreachable. Retry or choose another version?") with retry, switch version, and back actions. Never a silent black screen.
8. Leaving the player saves progress. Returning to the app shows the new resume point in Continue Watching.

### 4.5 Library management flow

**Fixing a match**
1. Open a film or show. Tap the "..." menu, then Fix Match.
2. Search TMDb by title and year. Results show posters so the user can pick visually.
3. Confirm. The app saves the override and refreshes artwork.

**Needs Review queue**
- Accessible from Settings and from a badge on Home.
- Each item shows the file path and the best guess. Actions: Accept, Fix Match, Ignore, Treat as Film, Treat as TV.
- Batch actions for multiple selections.

**Duplicates**
- A duplicate item shows a "2 versions" badge. The user sets a preferred version, and the other is hidden from the main library but still listed under the item.

### 4.6 Add-source flow (detail)

```
Sources > + > Choose type
  ├─ Local  → Document picker → select folder → tag → scan
  └─ Network
       ├─ Discovered device list (Bonjour/SSDP)  → select
       └─ Manual form (host, share/path, port, protocol)
            → credentials (optional, Keychain)
            → Test Connection
                ├─ OK      → folder picker → tag → scan
                └─ Failed  → error with fix hint (wrong password, host not reachable, port closed)
```

### 4.7 Scanning and background flow

- Scan triggers: on add, on manual "Refresh", on a schedule (default daily), and when the app is opened after a long gap.
- Scans are incremental: only new or changed files are read. Changed files are detected by path, size, and modified date.
- Scans pause on cellular unless the user allows it.
- A banner shows progress without blocking the library.

---

## 5. Screen inventory

| # | Screen | iPhone | iPad | Notes |
|---|---|---|---|---|
| 1 | Welcome | Yes | Yes | First run only |
| 2 | Add source | Yes | Yes | Sheet on iPad |
| 3 | Folder picker | Yes | Yes | Tree with tags |
| 4 | Home | Yes | Yes | Rows of cards |
| 5 | TV Shows grid | Yes | Yes | |
| 6 | Show detail | Yes | Yes | Split view on iPad |
| 7 | Season / episode list | Yes | Yes | |
| 8 | Films grid | Yes | Yes | |
| 9 | Film detail | Yes | Yes | Shows file info |
| 10 | Sources list | Yes | Yes | |
| 11 | Source browser | Yes | Yes | Plain file view |
| 12 | Search | Yes | Yes | |
| 13 | Player | Yes | Yes | Landscape only |
| 14 | Track sheets (audio, subtitles) | Yes | Yes | Bottom sheet |
| 15 | Chapters | Yes | Yes | |
| 16 | Fix Match | Yes | Yes | |
| 17 | Needs Review | Yes | Yes | |
| 18 | Collections and playlists | Yes | Yes | |
| 19 | Watch history | Yes | Yes | |
| 20 | Settings (all groups) | Yes | Yes | |

---

## 6. Technical decisions

**Decided**

1. **Playback engine: VLCKit, LGPL build.** Broadest format and codec support, mature, and it covers MKV. The LGPL build is the one distributed via CocoaPods/SPM as `MobileVLCKit` or `VLCKit`; it excludes GPL-only modules (notably some commercial-codec and DVD/Blu-ray menu libraries, which this app does not need). AVPlayer stays an optional MP4-only path, dropped if it adds complexity.
2. **Distribution: sideload now, TestFlight later.** Paid developer account is in place, so sideloads do not expire weekly and all capabilities (iCloud, background modes, Keychain groups) are available from day one.
3. **Pricing: free, no in-app purchases, no adverts.** This keeps the app non-commercial under TMDb, TheTVDB, Fanart.tv and OpenSubtitles terms. Attribution is still required for each.
4. **Licensing route: LGPL.** Dynamic linking of VLCKit as an XCFramework, licence notices in About, and the ability to relink is preserved by shipping the framework as a separate binary inside the app bundle. See section 10.1 for the obligations this takes on.
5. **Minimum iOS version: iOS 17.** Enables CKSyncEngine, SwiftData, modern SwiftUI navigation, and simplifies PiP and HDR handling.

**Open**

6. **Metadata providers.** TMDb is the backbone. TheTVDB for episode ordering and OpenSubtitles for subtitle search are recommended; confirm both are wanted.
7. **Network libraries.** Use an SMB client library (AMSMB2) and a WebDAV client, rather than writing protocol code from scratch. See section 11 for the full dependency list.

---

## 7. Build phases

**Phase 0: Spike (1 to 2 weeks)**
- Prove playback of 20 representative files: MKV with HEVC and DTS-HD, AVI with XviD, TS from a Blu-ray rip, ASS subtitles, PGS subtitles.
- Prove SMB read at acceptable seek speed over Wi-Fi.
- Output: a go/no-go note on the engine choice.

**Phase 1: Core player and local library**
- Local files, playback engine, controls, gestures, track selection, resume.
- Basic TV/Films classification and TMDb matching.
- iPhone and iPad layouts.

**Phase 2: Network sources**
- SMB first, then WebDAV, then DLNA.
- Source management, Keychain, discovery, folder tagging.
- Offline handling and error cards.

**Phase 3: Library quality**
- Fix Match, Needs Review, duplicates, collections, playlists, search.
- Subtitle search and sync.
- Up Next and auto-play.

**Phase 4: Sync and polish**
- iCloud sync of watch state and overrides.
- Background scanning, PiP, AirPlay, Now Playing.
- Accessibility pass (VoiceOver, Dynamic Type, reduced motion).

**Phase 5: Beta and release**
- TestFlight with a library test set covering edge-case naming.
- Performance pass on older devices.
- App Store submission and privacy labels.

---

## 8. Success criteria (v1)

- Plays at least 99% of files from a test corpus of 500 mixed files without transcoding, with audio and subtitles working.
- Starts playback from SMB within 3 seconds on a gigabit LAN.
- Classifies at least 90% of a typical library automatically, with the rest landing in Needs Review.
- Resumes playback within 1 second of the last saved position.
- No silent failures: every error produces a visible message and a recovery action.

---

## 9. Open questions

1. Which iOS versions and devices must be supported?
2. Is the app for personal use only, or intended for the App Store?
3. Is there a preference between a free app with optional paid features and a paid app?
4. Should Dolby Vision and Dolby Atmos passthrough be a v1 requirement, or later?
5. Which sources matter most for the first release (SMB only, or SMB plus WebDAV)?
6. Is iCloud sync a v1 requirement?
7. Any preferred visual style, or should the UI start from a clean SwiftUI default?

---

## 10. Licensing, free sources, and sync design

### 10.1 Licences in plain terms

A software licence sets what you may do with a library's code. It is separate from the terms of any online data service.

- **Your own code:** you choose the licence. Keeping the app closed-source is fine as long as every dependency allows it.
- **Permissive licences (MIT, BSD, Apache):** you may use the code in any app, including paid ones. You only need to credit the authors.
- **LGPL (VLCKit's core):** you may use the library in a closed-source app. You must keep its licence notice, credit it in About, and let the library be swapped or relinked. Dynamic linking makes that simple. Some VLC builds also include GPL components, and GPL can extend to the whole app. Check the exact build you use.
- **GPL:** if GPL code is linked into your app, the whole app must be GPL and its source published. Apple's App Store terms are generally seen as incompatible with that, so GPL-only builds are a problem for App Store or TestFlight distribution later.
- **Media and artwork:** films, shows, and poster images are copyrighted by their owners. Playing your own files is fine. The app ships no content. Artwork fetched from APIs is for display under each provider's terms.
- **API terms:** TMDb and others set their own rules on attribution, commercial use, and rate limits. These apply on top of any code licence.

This is not legal advice. Have a lawyer check the final setup before App Store release.

### 10.2 What "free" means here

Decision: **free with no in-app purchases and no adverts.** That places the app in the non-commercial tier of every provider below, both for sideload and later for TestFlight or the App Store. If this ever changes (ads, IAP, donations, a paid tier), each provider's terms must be re-read and commercial licences obtained where needed.

**LGPL obligations this app takes on**

- Ship VLCKit as a dynamically linked framework, not statically linked into the main binary.
- Include the VLCKit and FFmpeg licence texts and a list of the LGPL components in Settings > About > Licences.
- Do not modify VLCKit. If a change is ever needed, publish that modified library source.
- Keep the app's own source closed if desired; LGPL does not require opening it.

### 10.3 Free data sources

| Provider | Used for | Cost and key | Terms to note |
|---|---|---|---|
| TMDb | Films, TV, cast, posters, backdrops | Free API key | Free for non-commercial use with attribution and logo. Commercial use needs a licence. |
| TheTVDB | Episode order, alternative episode data | Free key for personal use | Check current terms; commercial use typically needs a paid plan. |
| Fanart.tv | Extra art: logos, clear art, banners | Free key | Attribution required. Check terms for commercial use. |
| OpenSubtitles | External subtitle search and download | Free account, daily download quota | Check current API terms and quota rules. |
| Wikidata | Cross-IDs between providers | Free | CC0, no restrictions. |
| Wikipedia | Synopsis fallback | Free | CC BY-SA: attribution, and share-alike if text is copied. |
| Wikimedia Commons | Some imagery | Free | Licence varies per file. Record it per image. |
| Trakt | Optional alternative watch-history sync | Free for personal apps, app registration | Check terms if the app is ever commercial. |
| IMDb | Not recommended | No public API | Scraping breaks its terms. Avoid. |

Use TMDb as the backbone. Add the others only where they fill a real gap, and show attribution for each on the About screen.

### 10.4 iCloud sync design

**Storage:** CloudKit private database, synced with CKSyncEngine (iOS 17+). The data sits in the user's own iCloud, counts against their iCloud storage, and needs no server from you.

**Requirement:** the iCloud capability needs the paid developer account, which is in place.

**What syncs**
- Watched flag and last-played date, per item.
- Resume position, per item.
- Favourite flag, per show, film, or episode.
- Library overrides (Fix Match choices, hidden items, collections).

**What never syncs**
- Source addresses and credentials. These stay in the device Keychain.
- Local file paths. They differ between devices.
- Artwork and metadata caches. These are re-downloaded per device.

**Item identity:** sync by a stable key, not a device path. A film on a NAS mounted under two different names must still match.
- Matched films: `movie:<tmdbId>`
- Matched episodes: `show:<tmdbId>:S02E05`
- Unmatched files: hash of filename, file size, and duration.

**Conflict rules**
- Watched: once watched on any device, stays watched unless the user marks it unwatched later (latest timestamp wins).
- Resume position: latest timestamp wins.
- Favourite: latest timestamp wins, with a tombstone so removals sync.

**Write frequency:** resume positions write on pause, on exit, and every 30 seconds during playback. Not every second, to keep iCloud traffic low.

**Offline:** writes go to a local store first and sync when iCloud is reachable.

**Sign-in:** none. Sync is on when the device is signed into iCloud and the user has enabled it in Settings.

---

## 11. Solution design

This section turns each feature area into a concrete approach: libraries, data model, and the handful of algorithms that matter.

### 11.1 Architecture overview

```
┌────────────────────────────────────────────────────────────┐
│ SwiftUI app (iPhone + iPad)                                 │
│  Home · TV · Films · Sources · Search · Player · Settings    │
├────────────────────────────────────────────────────────────┤
│ Feature layer (observable view models)                      │
│  LibraryStore · PlaybackController · SourceManager · Sync    │
├──────────────┬──────────────┬──────────────┬───────────────┤
│ Playback     │ Sources      │ Metadata     │ Persistence   │
│ VLCKit       │ AMSMB2 (SMB) │ TMDb client  │ SwiftData     │
│ AVPlayer*    │ WebDAV       │ TheTVDB      │ CloudKit      │
│ NowPlaying   │ FTP/SFTP     │ Fanart.tv    │ Keychain      │
│ PiP/AirPlay  │ DLNA/UPnP    │ OpenSubs     │ Image cache   │
│              │ Files/USB    │ Wikidata     │               │
└──────────────┴──────────────┴──────────────┴───────────────┘
   * optional MP4-only path
```

- **Language and UI:** Swift 5.10+, SwiftUI with UIKit hosting only for the VLC render view.
- **Concurrency:** Swift structured concurrency. One actor per source for connection state; one actor for the scan queue.
- **Persistence:** SwiftData for the library (items, files, sources, watch state). CloudKit via CKSyncEngine for the sync subset.
- **Modules:** Swift packages per layer (`Playback`, `Sources`, `Metadata`, `Library`, `Sync`, `UI`) so each can be tested without the app target.

### 11.2 Playback with VLCKit

**Integration**
- Add `VLCKit` (iOS, LGPL) via Swift Package Manager as an XCFramework.
- Wrap `VLCMediaPlayer` in a `PlaybackController` actor exposing a Swift-friendly stream of state: `.idle`, `.buffering(progress)`, `.playing(time)`, `.paused(time)`, `.ended`, `.failed(error)`.
- Render into a `UIView` hosted in SwiftUI with `UIViewRepresentable`. The view handles `drawable` assignment and aspect-ratio mode (fit, fill, zoom).

**Decoding**
- Enable VideoToolbox hardware decoding via VLC options (`--codec=avcodec` with `--avcodec-hw=videotoolbox`). Fall back to software when hardware fails for a stream.
- HDR: VLCKit passes HDR10 and HLG through to the display on iOS 17. Dolby Vision profiles 5 and 8 fall back to the HDR10 base layer. Document this limitation in Settings.

**Tracks**
- Audio and subtitle tracks are enumerated from `VLCMediaPlayer.audioTrackIndexes` and `videoSubTitlesIndexes`, with names and languages from the track descriptions. Switching is live.
- External subtitles: `addPlaybackSlave(_:type:enforce:)` for SRT, ASS, VTT, SUB/IDX. ASS styling is rendered by libass inside VLC.
- Subtitle delay and audio delay map directly to `currentVideoSubTitleDelay` and `currentAudioPlaybackDelay` (microseconds).

**Seeking and thumbnails**
- Seek via `time` or `position`. Scrub preview thumbnails come from a second, muted `VLCMediaThumbnailer` run in the background at 10-second intervals, cached per file.

**Streaming from network sources**
- SMB: VLCKit has a built-in SMB module, but credential handling and discovery are better in the app. Approach: mount via AMSMB2 for browsing and metadata, and hand VLC an `smb://user:pass@host/share/path` URL for playback so VLC does its own buffered reads. Credentials are URL-encoded from the Keychain at play time only.
- WebDAV/HTTP: pass the authenticated `https://` URL; VLC handles range requests.
- FTP/SFTP: VLC supports `ftp://` and `sftp://` natively.
- Local: a `file://` URL from a security-scoped bookmark.

**Buffering**
- Set `network-caching` to 1500 ms by default, adjustable in Settings (500 to 5000 ms). Show a buffering spinner only after 400 ms to avoid flicker.

**System integration**
- `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` for lock screen and Control Centre.
- Background audio via the `audio` background mode; video pauses, audio continues if the user enables "Play audio in background".
- PiP: VLCKit does not render through `AVPlayerLayer`, so native PiP needs an `AVSampleBufferDisplayLayer` bridge. This is the riskiest item in the engine. Plan: ship without PiP in phase 1, add it in phase 4 via the sample-buffer bridge, and treat it as cut-able.
- AirPlay: video AirPlay of VLC-decoded content is screen mirroring, not native streaming. Audio-only AirPlay works via the system route picker. Document this honestly in Settings.

### 11.3 Source access

| Source | Library | Approach |
|---|---|---|
| SMB | AMSMB2 (MIT) | Browse, stat, and read. Also used for the scan. Play via VLC's SMB URL. |
| WebDAV | Custom thin client over `URLSession` (PROPFIND, GET with Range) | Small enough to own. |
| FTP/SFTP | VLC for playback; `NMSSH` or `Citadel` for SFTP listing; plain `URLSession` for FTP listing | Low priority. |
| DLNA/UPnP | SSDP discovery over UDP multicast; ContentDirectory browse over SOAP | Read-only. Playback via the HTTP URL the server gives. |
| Local / USB | `UIDocumentPickerViewController` with `.open` mode, security-scoped bookmarks persisted | No copying; files stay in place. |
| iCloud Drive | Same document picker; files download on demand | Show a download indicator. |

**Discovery**
- Bonjour: browse `_smb._tcp.` and `_afpovertcp._tcp.` for NAS hosts.
- SSDP: `M-SEARCH` for `urn:schemas-upnp-org:device:MediaServer:1`.
- Results merge into one list with host name, IP, and protocol badges.

**Credentials**
- Stored in the Keychain with `kSecAttrAccessibleAfterFirstUnlock`, keyed by source ID. Never written to SwiftData or CloudKit.
- Each source has a `SourceConnection` actor that holds one open session, retries with exponential backoff (1 s, 2 s, 4 s, max 3), and reports `online`, `offline`, or `authFailed`.

**Scanning**
- A `ScanQueue` actor processes one source at a time, breadth-first, with a max of 4 concurrent `stat` calls per source.
- Incremental: a file is "changed" if path, size, or modified date differs from the stored `MediaFile`.
- Only video extensions are considered: mkv, mp4, m4v, mov, avi, ts, m2ts, mts, wmv, flv, webm, mpg, mpeg, vob, 3gp, ogv.
- Sidecar subtitles (same base name, `.srt`, `.ass`, `.sub`, `.idx`, `.vtt`) are attached to the file record.
- Background: `BGAppRefreshTask` requested daily; iOS decides when to run it. Full scans happen on manual refresh or app open.

### 11.4 Classification and matching

**Step 1: parse the path**

A deterministic parser runs on the full relative path, not just the filename. It extracts title, year, season, episode, quality tags, and release-group noise.

Rules, in order:
1. Episode patterns on the filename: `S(\d{1,2})E(\d{1,3})`, `(\d{1,2})x(\d{1,3})`, `Season (\d+).*Episode (\d+)`, `E(\d{2,3})` when the parent folder matches `Season \d+`.
2. Year on the filename or parent folder: `\((19|20)\d{2}\)` or `\.(19|20)\d{2}\.`.
3. Strip quality and source tags: `1080p`, `2160p`, `4K`, `BluRay`, `WEB-DL`, `x264`, `x265`, `HEVC`, `HDR`, `DV`, `Atmos`, `DTS`, `REMUX`, and anything after a `-GROUP` suffix.
4. Normalise separators (`.`, `_`) to spaces and trim.

**Step 2: weigh folder hints**

| Path contains | Effect |
|---|---|
| `tv`, `series`, `shows` | +2 toward TV |
| `movies`, `films`, `cinema` | +2 toward Film |
| `Season NN` parent | +3 toward TV |
| User-tagged folder (Films / TV) | overrides everything |

**Step 3: decide**

- Episode pattern found → TV.
- Year found, no episode pattern → Film.
- Neither → Needs Review, with a best guess shown.

**Step 4: match online**

- TV: `GET /search/tv?query=<title>&first_air_date_year=<year?>`, pick the top result if its popularity is well ahead of the second; otherwise Needs Review with the top 3 shown.
- Film: `GET /search/movie?query=<title>&year=<year>`, same rule.
- Episode details: `GET /tv/{id}/season/{s}/episode/{e}`.
- Confidence is stored per match (`auto-high`, `auto-low`, `manual`). Low-confidence matches get a small badge so the user can spot them.

**Step 5: cache**

- Every TMDb response is cached on disk for 7 days (metadata) or indefinitely (artwork, until the cache limit evicts it). Requests are throttled to stay under TMDb's rate limit (currently ~40 requests per 10 seconds).

### 11.5 Artwork pipeline

- Poster sizes: `w342` for grids, `w780` for detail. Backdrops: `w1280`. Episode stills: `w300`.
- Download through a dedicated `ImageLoader` actor with an in-memory `NSCache` and a disk cache under `Caches/artwork/`.
- Disk cache limit default 2 GB, adjustable; LRU eviction.
- Placeholder: a generated gradient from the title's hash with the first letter, so grids never show empty boxes.
- Fanart.tv (optional) adds clear logos used on the detail hero and in the Up Next card.

### 11.6 Data model

```
Source            id, name, type, host, path, folderRules[], lastScan, status
MediaFile         id, sourceId, relativePath, size, modified, duration?, videoCodec?, audioTracks[], subtitleTracks[], sidecars[]
MediaItem         id, kind (film|show|episode), tmdbId?, title, year, overview, posterPath, backdropPath, matchConfidence
Show              item + seasons[]
Episode           item + showId, season, episode, airDate, stillPath
Film              item + runtime, collectionId?
WatchState        itemKey, watched, position, duration, updatedAt, deviceId     ← synced
Favourite         itemKey, createdAt, deletedAt?                               ← synced
Override          itemKey, forcedTmdbId?, hidden, kindOverride?, updatedAt     ← synced
Collection        id, name, itemKeys[], updatedAt                              ← synced
Playlist          id, name, itemKeys[], updatedAt
```

`itemKey` is the stable sync identity from section 10.4. A `MediaFile` points to one `MediaItem`; an item can have several files (versions).

### 11.7 iCloud sync implementation

- `CKSyncEngine` with one private zone `Library`.
- Record types mirror the synced tables above. Each record carries `updatedAt` and `deviceId`.
- Local changes are queued in SwiftData, then pushed. Remote changes are applied by `updatedAt` comparison (latest wins), with the watched-flag special case from section 10.4.
- Deletes use tombstones (`deletedAt`) rather than hard deletes, so a favourite removed on one device clears everywhere.
- Account changes (`CKAccountChanged`) reset the sync state and re-fetch.
- Sync toggle in Settings. Off means local only; turning it on later performs a merge.

### 11.8 Error handling

Every failure maps to one of a small set of user-facing cards, each with a recovery action:

| Failure | Card | Actions |
|---|---|---|
| Source unreachable | "Can't reach <source>" | Retry, Open Sources, Pick another version |
| Auth failed | "Password rejected for <source>" | Edit credentials |
| File missing | "File not found. It may have been moved." | Rescan, Remove from library |
| Unsupported stream | "This file's <codec> track can't be decoded on this device." | Try software decoding, Skip |
| Metadata offline | Silent; cached data shown | Banner: "Metadata unavailable, showing cached info" |

### 11.9 Testing strategy

- **Playback corpus:** 50 files covering MKV/HEVC/DTS-HD, MKV/H.264/AC3, AVI/XviD/MP3, TS/MPEG-2, WebM/VP9/Opus, MP4/AV1, PGS and ASS subtitles, multi-audio, 4K HDR10, Dolby Vision profile 8. Run on an iPhone 12 (lowest target) and an iPad Pro.
- **Parser tests:** a table of 200 real-world filenames with expected title, year, season, episode, and kind. Pure unit tests, run on every commit.
- **Source tests:** a Docker Samba server and a WebDAV server in CI for connect, list, stat, read, and seek.
- **Sync tests:** two simulators against the CloudKit development environment; assert convergence for watched, resume, and favourite.
- **UI tests:** snapshot tests for each screen on iPhone 15 and iPad Pro 12.9, light and dark.

### 10.x Sync scope revision (24 Oct 2026)

Decided by the owner: the scanned library syncs as well, so a second device does not repeat the scan and
matching. `Source` records carry everything except the password (iCloud Keychain carries that, end-to-end
encrypted, outside the app's CloudKit container); `Item` and `File` records use deterministic names so
devices converge; Files-app sources stay device-local. Credentials and playback URLs are still never in CloudKit.

### 11.10 Dependencies

| Package | Purpose | Licence |
|---|---|---|
| MobileVLCKit 3.7.3 (VideoLAN binary, dynamic xcframework, fetched by `Scripts/fetch-vlckit.sh`; no SwiftPM package exists) | Playback | LGPL 2.1 |
| AMSMB2 4.x | SMB browsing | MIT |
| AniDB titles dump (anidb.net/api/anime-titles.xml.gz) | Anime title recognition, offline | AniDB non-commercial terms; attribution in Settings |
| Anime-Lists (github.com/Anime-Lists/anime-lists) | AniDB → TMDb season/episode mapping | Public data file; attribution in Settings |
| TheTVDB v4 API (user's own project key) | Fallback show search bridged to TMDb | TheTVDB attribution required; shown in Settings |
| Nuke or own ImageLoader | Image caching | MIT |
| swift-log | Logging | Apache 2.0 |
| KeychainAccess | Keychain wrapper | MIT |
| swift-snapshot-testing | UI tests | MIT |

Everything other than VLCKit is permissive. All notices go in Settings > About > Licences.

### 11.11 Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| PiP with VLCKit | No native PiP | Sample-buffer bridge in phase 4; cut if it fails |
| Video AirPlay is mirroring only | Lower quality on Apple TV | Document; consider AVPlayer path for MP4 later |
| Dolby Vision profile 5 | Washed-out colour | Detect and warn; fall back to HDR10 |
| SMB seek speed on Wi-Fi | Slow scrubbing | Larger network cache; thumbnail pre-generation |
| TMDb rate limits during a 5000-file first scan | Slow matching | Throttle, cache, match visible items first |
| Battery on software decode | Hot device | Prefer hardware; warn when software decode is active |

---

## 12. Code layout and first-build checklist

The code lives in two places:

```
Reel/                      SwiftUI app target (generated .xcodeproj via project.yml)
  App/                     ReelApp, AppSettings, PlayerCoordinator, RootView
  Views/Library            Home, TV, Films, detail pages, Search, Needs Review, Fix Match
  Views/Sources            Sources, Source detail, Add Source, file browser, folder tags
  Views/Player             PlayerView (gestures, scrubber, sheets, Up Next, error card), VLCVideoView
  Views/Settings           Settings, history, hidden items, licences, attribution
  Views/Components         ArtworkImage, PosterCard, FilterBar, ItemGrid/ItemRow
Packages/ReelKit/          One Swift package, six modules
  MediaCore                Models, FilenameParser, Classifier, ItemKey, formatting    (pure Swift, tested)
  Metadata                 TMDbClient, cache, rate limiter, MatchScorer                (Foundation, tested)
  MediaSources             MediaSource protocol, Local, WebDAV, SMB, discovery, Keychain
  Playback                 PlaybackEngine protocol, VLCPlaybackEngine, NowPlayingBridge
  Library                  SwiftData schema, LibraryScanner, Matcher, LibraryStore, ImageLoader
  Sync                     SyncEngine (CKSyncEngine)
```

Written without Xcode access, so the first build will surface a few compile errors. Where to look first, in order of likelihood:

1. **VLCKit package URL and product name** (`Package.swift`, `Playback` target). VideoLAN has renamed these. Fix the URL/product and the `import VLCKit` / `import MobileVLCKit` fallback in `VLCPlaybackEngine.swift` picks up whichever exists.
2. **VLCKit 3.x API spelling** in `VLCPlaybackEngine.swift`: `audioTrackIndexes`/`audioTrackNames`, `videoSubTitlesIndexes`/`videoSubTitlesNames`, `chapterDescriptions(ofTitle:)`, `VLCChapterDescriptionName`. If a name differs, Xcode's fix-it will point at the right one.
3. **AMSMB2 async API** in `SMBSource.swift`: `connectShare(name:)`, `contentsOfDirectory(atPath:)`, `attributesOfItem(atPath:)`. All exist in 3.x; check the returned attribute keys if listings come back empty.
4. **SwiftData `#Predicate` expressions** in `LibraryStore.swift` and `SyncEngine.swift`. The macro rejects some expressions (e.g. captured optionals). Simplify the predicate and filter in Swift if one is refused.
5. **`CKSyncEngine` delegate signatures** in `SyncEngine.swift`. Both delegate methods are `nonisolated` and hop to the main actor; if Xcode complains about isolation, mark the class `nonisolated` for those two methods only.
6. **Strict-concurrency warnings.** `SWIFT_STRICT_CONCURRENCY` is set to `minimal` in `project.yml` on purpose for the first build. Tighten it later.

Once it builds, the device smoke test is:

1. Add a TMDb key in Settings. Add a local folder with two or three MKVs. Confirm the scan banner, then posters on Home.
2. Add the NAS over SMB. Test Connection must fail cleanly with a wrong password (red banner) and succeed with the right one.
3. Play an MKV with multiple audio tracks and a PGS subtitle. Switch both mid-playback. Scrub. Lock. Close, reopen, confirm resume.
4. Mark an episode watched on iPhone, open iPad, confirm the tick arrives (iCloud sync on, same Apple ID).
5. Put a badly named file in a folder and confirm it lands in Needs Review; fix it via Fix Match.
