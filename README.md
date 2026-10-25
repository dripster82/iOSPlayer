<p align="center"><strong>Reel</strong></p>
<p align="center">Every file. Every screen.</p>
<p align="center"><a href="https://dripster82.github.io/iOSPlayer/">Website</a> · <a href="https://dripster82.github.io/iOSPlayer/support.html">Support</a> · <a href="https://dripster82.github.io/iOSPlayer/privacy.html">Privacy</a> · <a href="https://dripster82.github.io/iOSPlayer/terms.html">Terms</a></p>

Reel is a media player for iPhone and iPad that plays your own video files, straight from a NAS share
or the device, and turns them into a proper library: TV shows and films with artwork, episode names,
cast, collections, continue watching and next up. There is no account, no server to install and
nothing is uploaded anywhere.

## What it does

**Plays almost anything.** MKV, MP4, AVI, WebM and more, through VLC's engine: HEVC and 10-bit video,
Dolby and DTS audio, embedded and external subtitles, chapters, playback speed, audio and subtitle
delay. Hardware decoding where the device has it.

**Straight from your NAS.** SMB and WebDAV shares, or folders on the device. Reel reconnects on its
own when a share drops, and can send Wake-on-LAN to a NAS that has gone to sleep.

**A real library.** Titles, posters, backdrops, episode names, cast and ratings from
[TMDB](https://www.themoviedb.org), matched from your file names. Anime is recognised by its own
titles through AniDB and Anime-Lists. Anything Reel is unsure about goes to Needs Review, where a
whole folder can be fixed at once; Fix Match sets any title straight, with an Anime option.

**Made for watching.** Skip intro (from chapters, or learned from your own skips), live preview
frames while scrubbing, resume or start over, auto-play next with a countdown, a sleep timer,
dialogue boost for quiet speech, Picture in Picture, AirPlay, keyboard shortcuts on iPad.

**Finds things.** Continue Watching and Next Up on Home, favourites, your own collections, smart
collections that fill themselves, film series and universes (Marvel, Pixar, Star Wars and the like),
people pages with filmographies, and a search that covers titles, people and collections.

**Picks up where you left off.** Progress, favourites, collections, match fixes and sources sync
between your devices through your own iCloud. Passwords travel only through iCloud Keychain.

**Offline.** Download films or whole seasons to the device.

**Try it without a server.** The first screen offers a sample library, three short films and a
show built into the app, so you can look around before adding a share.

## Metadata and artwork

Reel ships with its own keys for TMDB, fanart.tv and OpenSubtitles, so there is nothing to register
for. Your own keys can be added in Settings → Metadata: a TMDB key overrides the built-in one; a
fanart.tv personal key is sent alongside the project key, as fanart.tv asks, and brings newly
approved images sooner; subtitle downloads use your own OpenSubtitles account because quotas are per
person. TheTVDB is an optional fallback that needs your own key and subscriber PIN.

This product uses the TMDB API but is not endorsed or certified by TMDB. Logos and extra artwork
are images from [fanart.tv](https://fanart.tv). Anime titles come from [AniDB](https://anidb.net)
and the [Anime-Lists](https://github.com/Anime-Lists/anime-lists) mapping. Subtitles from
[OpenSubtitles](https://www.opensubtitles.com). Playback by [VLCKit](https://code.videolan.org/videolan/VLCKit)
(LGPL 2.1, dynamically linked). The full review of each provider's terms is in
[docs/METADATA-TERMS.md](docs/METADATA-TERMS.md).

## Privacy

No analytics, no advertising, no tracking, no account. The only things that leave the device are
requests to the servers you add and to the metadata services above, and your own iCloud if you turn
sync on. The [privacy policy](https://dripster82.github.io/iOSPlayer/privacy.html) has the detail.

## Building from source

Xcode 15.3 or later, iOS 17. Install XcodeGen, fetch VLCKit once, generate the project:

```sh
brew install xcodegen
Scripts/fetch-vlckit.sh
xcodegen generate && open Reel.xcodeproj
```

Shipped API keys go in `Secrets.xcconfig` (git-ignored; copy `Secrets.example.xcconfig`). Tests:
`cd Packages/ReelKit && swift test`. Everything else, including signing, iCloud setup, the VLCKit
licence arrangement and the feature status table, is in [BUILDING.md](BUILDING.md); the project
history and decisions are in [HANDOVER.md](HANDOVER.md).

## Support

[Support page](https://dripster82.github.io/iOSPlayer/support.html) ·
[GitHub Issues](https://github.com/dripster82/iOSPlayer/issues) · barley_gilt6r@icloud.com

Made by dripster82.
