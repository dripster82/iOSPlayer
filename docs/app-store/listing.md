# App Store Connect — listing material for Reel 1.0

Everything here is ready to paste. Fields are in App Store Connect order.

## App information

| Field | Value |
|---|---|
| Name | Reel |
| Subtitle (30) | Your films and shows, from your NAS |
| Bundle ID | uk.co.ketelle.reel |
| SKU | reel-ios |
| Primary category | Entertainment |
| Secondary category | Utilities |
| Primary language | English (U.K.) |
| Content rights | Does not contain, show or access third-party content (the app plays the user's own files) |
| Age rating | 4+ (no app-supplied content; questionnaire answers all "None") |
| Price | Free |

## URLs

| Field | Value |
|---|---|
| Support URL | https://dripster82.github.io/iOSPlayer/support.html |
| Marketing URL | https://dripster82.github.io/iOSPlayer/ |
| Privacy policy URL | https://dripster82.github.io/iOSPlayer/privacy.html |
| Terms (EULA) | Standard Apple EULA, with https://dripster82.github.io/iOSPlayer/terms.html linked from the description |

## Promotional text (170)

Plays your own films and shows straight from a NAS share or the device, with artwork, episode names, Continue Watching and AirPlay to the TV. No account, no server, nothing uploaded.

## Description (4000)

Reel turns the video files you already have into a proper library, and plays them.

Point it at a share on your NAS (SMB, WebDAV, FTP, SFTP, NFS or a DLNA media server) or a folder on the device, and Reel finds your films and TV shows, names them, and fills in posters, backdrops, episode titles, cast and ratings from TMDB. Anime is recognised by its own titles. Anything it isn't sure about goes to Needs Review, where a whole folder can be fixed at once.

Plays almost anything. MKV, MP4, AVI, WebM and more through VLC's engine: HEVC and 10-bit video, Dolby and DTS audio, embedded and external subtitles, chapters, playback speed, audio and subtitle delay, hardware decoding.

Made for watching. Skip intro, live preview frames while scrubbing, resume or start over, auto-play next with a countdown, a sleep timer, dialogue boost for quiet speech, Picture in Picture, keyboard shortcuts on iPad.

AirPlay with the picture. Send a film to an Apple TV and the video goes with it, including MKV files, which Reel repackages on the fly; the TV gets the audio track you chose and your subtitles. Files AirPlay cannot carry as they are (XviD, MPEG-2) are converted on the device as they stream. Or mirror the screen and Reel fills the TV with the picture while the controls stay on the iPad.

Finds things. Continue Watching and Next Up on Home, favourites, your own collections, smart collections that fill themselves, film series and universes, people pages with filmographies, and a search that covers titles, people and collections.

Picks up where you left off. Progress, favourites, collections, match fixes and sources sync between your devices through your own iCloud. Passwords travel only through iCloud Keychain.

Offline. Download films or whole seasons to the device.

Try it without a server. The first screen offers a sample library built into the app, so you can look around before adding a share.

Reel has no account, no analytics, no advertising and no tracking. The only things that leave the device are requests to the servers you add and to the metadata services, and your own iCloud if you turn sync on.

This product uses the TMDB API but is not endorsed or certified by TMDB. Extra artwork from fanart.tv. Anime titles from AniDB and Anime-Lists. Subtitles from OpenSubtitles. Playback by VLCKit (LGPL 2.1; source at https://github.com/dripster82/iOSPlayer).

Terms: https://dripster82.github.io/iOSPlayer/terms.html

## Keywords (100)

nas,smb,mkv,media player,video player,plex,infuse,airplay,hevc,subtitles,tv shows,films,library

## What's new (1.0)

First release.

## App Privacy (the questionnaire)

- Does the app collect data? **No.** Nothing is sent to the developer or any analytics service. Requests go only to servers the user adds and to the metadata providers for titles and artwork, and sync data goes to the user's own iCloud.
- Tracking: **No.**
- Privacy manifest: `Reel/Resources/PrivacyInfo.xcprivacy` (UserDefaults CA92.1, file timestamps C617.1; no collected data, no tracking domains).

## App Review notes (paste into "Notes")

Reel plays the reviewer's own video files from a network share; a NAS is not needed to review it.

1. On first launch choose "Try the sample library". It installs three short films and a three-episode show bundled with the app, so every screen (Home, Films, TV Shows, a film page, the player, Collections, Search, Settings) can be exercised without any server.
2. To review a network source, Sources → + lists any SMB, WebDAV, FTP, SFTP, NFS or DLNA server on the same Wi‑Fi, or one can be entered by address. Any WebDAV or SMB test server works.
3. AirPlay: play a sample film, then choose an Apple TV from the AirPlay control in the player. The video is sent, not just the audio.
4. Background modes: *audio* keeps playback going when the screen locks; *processing* refreshes the library overnight (BGProcessingTask uk.co.ketelle.reel.scan); *remote-notification* receives CloudKit change pushes for sync. No audio plays in the background unless the user started it.
5. Local network permission is requested when the Sources screen looks for servers (Bonjour and a subnet probe); it is explained in the prompt text.
6. Export compliance: the app uses only standard encryption (HTTPS, SMB 3 signing, SSH via VLCKit's libssh2); ITSAppUsesNonExemptEncryption is false.

Demo account: not applicable (there is no sign-in).

## Screenshots

Required sets: iPhone 6.9" (1320 × 2868) and iPad 13" (2064 × 2752), 3–10 each. Capture from the iPhone 17 Pro Max and iPad Pro 13" simulators at native scale with the sample library or a curated share; the downscaled copies in `docs/screenshots` are for the website only and are too small for App Store Connect.

Suggested order: Home · Film page · Player (with chapters) · TV show page · Collections · Search · Needs Review (iPad only) · Settings → Metadata.

## Before submitting

- [ ] Secrets.xcconfig filled (TMDB, fanart.tv, OpenSubtitles) and `Scripts/ensure-secrets.sh` passing
- [ ] Apple ID signed in to Xcode; app record created in App Store Connect
- [ ] CloudKit schema deployed to Production; `aps-environment` production in the archive's entitlements
- [ ] Build number bumped (CURRENT_PROJECT_VERSION) for each upload
- [ ] Archive with the Release configuration; debug links, the command poller and VLC's log are compiled out
- [ ] Screenshots uploaded at the sizes above
