# Metadata providers: what Reel may ship, and under what terms

Checked 25 October 2026. "Fetched" means the terms page was read on that date; "blocked" means the
site refused automated reads (Cloudflare) and the notes rely on the provider's published developer
documentation as last known, which should be re-read in a browser before submission.

| Provider | Used for | Key in the app? | Verdict for a free App Store build |
|---|---|---|---|
| TMDB | titles, artwork, episodes, cast, collections | **Yes, one app key** | Allowed for a free app with attribution. Paid app or ads needs a commercial agreement. |
| fanart.tv | logos, extra backgrounds | **Yes, a project key**; users may add a personal key, sent alongside | Allowed for a free app with attribution; terms met (see below). |
| TheTVDB | fallback show search, artwork ids | **Project key yes, but every user must subscribe (PIN)**, or a negotiated licence | Keep as an optional, user-keyed extra, or drop it. Do not ship a key without subscriptions. |
| OpenSubtitles | subtitle search and download | **App (consumer) key yes**; downloads need the user's own account | Ship the consumer key for search; keep user login for downloads. Blocked, re-check. |
| AniDB | anime title index (daily dump) | No key. One download a day, identifiable user agent, cached | Allowed. Keep the weekly refresh and the Reel user agent. Blocked, re-check. |
| Anime-Lists | AniDB to TMDB/TheTVDB mapping | No key. Public GitHub file, **no licence stated** | Low risk, credit it; ask the maintainers or vendor a copy with credit. |

## TMDB (fetched: api-terms-of-use, developer FAQ)

- "Our API is free to use for non-commercial purposes as long as you attribute TMDB as the source of the
  data and/or images." Commercial use, which includes "charging users a fee for Your Application",
  "is only permitted under a separate written agreement".
- Attribution: use an approved TMDB logo, less prominent than Reel's own branding, in an About or
  Credits section, with the notice "This product uses the TMDB API but is not endorsed or certified by
  TMDB." Reel's Settings → About → Data providers has the notice; it needs the logo added.
- Caching: nothing from TMDB may be cached "for longer than 6 months". Reel's metadata cache and the
  artwork cache need an expiry of six months (artwork is LRU by size only today).
- The key: the terms do not address embedding one key in a distributed app, which is how every
  TMDB-backed player (Infuse, Plex, Kodi scrapers) works. The licence is "non-sublicensable" and
  TMDB may end it "at any time for any reason". Ship one key, keep the user-key field as an override,
  and do not print the key anywhere. If Reel is ever paid, write to sales@themoviedb.org first.
- No numeric rate limit is published; "excessive bandwidth" is at TMDB's discretion. Reel's matcher
  already serialises requests and caches responses.

## TheTVDB (fetched: FAQ 62, API information page, terms of service)

- "v4 API keys are now per-project, and not for use by individual users." Two models: a negotiated
  commercial licence, or a user-supported key where "all end users of a project [must] sign up for a
  user subscription" (about $12 a year) and enter a subscriber PIN alongside the project key.
- "All API keys are required to have either a commercial license, or have subscriptions enabled for
  end users." There is no free tier for an app's users without a PIN.
- The API licence "does not give you the right to use or display images, trailers or programming
  associated with the API Content"; image rights are the developer's problem.
- Attribution: "Metadata provided by TheTVDB. Please consider adding missing information or
  subscribing." with a link, displayed to end users. Present in Reel's data providers page.
- Verdict: TheTVDB is only a fallback search in Reel and fanart.tv keys shows by TheTVDB id. Either
  keep it exactly as now (user supplies key and PIN) or remove it before submission. Shipping a project
  key for users without subscriptions would breach the terms.

## fanart.tv (terms of use, provided 25 October 2026)

The terms, verbatim:

> If you have a publicly available program, you must inform your users of this website and the images you use.
> You should allow your users to input their own API key into your application, this should be sent in addition to your project key.
> Do not use our API methods embedded in your own API for 3rd party use.
> Do not use our API for commercial use without written consent.
> Do not perform more requests than are necessary for each user. This means no downloading all of our content. Play nice with our server.
> Do not directly access our data without using the documented API methods.
> You MUST keep the email address in your account information current and accurate in case we need to contact you regarding your key.

How Reel meets each one:

- **Inform users of the site and the images.** Settings → About → Data providers names fanart.tv,
  says which pictures come from it, and links to fanart.tv. The website's data providers section does
  the same.
- **Users may add their own key, sent in addition to the project key.** Settings → Metadata keeps a
  fanart.tv personal key field; it is sent as `client_key` on every request alongside the shipped
  project key (`api_key`), never instead of it.
- **No re-serving through our own API.** Reel has no server; every request goes from the device to
  fanart.tv's documented v3 endpoints.
- **Non-commercial.** Reel is free with no ads or purchases. If that changes, written consent from
  fanart.tv is needed first.
- **Only necessary requests.** One request per title, when its detail page is first opened or Edit
  artwork is used, cached for seven days (and never past six months); nothing is bulk-fetched.
- **Documented methods only.** `movies/{tmdbID}` and `tv/{tvdbID}` on webservice.fanart.tv/v3.
- **Account email.** The project key is registered to the support address; keep it current.

## OpenSubtitles (blocked; from the REST API documentation as last read)

- An application registers as a **consumer** and gets an API key that is sent with every request.
  Searching works with the key alone; downloading needs a user JWT, obtained by logging the user in
  with their own OpenSubtitles account, with a daily quota per user (free accounts a small number a
  day, VIP more).
- The consumer key identifies the app and is meant to ship with it. Apps must not share one user's
  login across users, and a "commercial" consumer tier exists for apps with many users; the docs say
  to contact them above a usage threshold.
- Verdict: ship the consumer key, keep the per-user login for downloads (already how Reel works),
  and show the OpenSubtitles name on the providers page. Re-read opensubtitles.stoplight.io in a
  browser before submission.

## AniDB (blocked; from the API wiki as last read)

- The titles dump (anime-titles.xml.gz) is published for exactly this use. Rules: download it at most
  once per day, send an identifying user agent, and cache it locally. Reel refreshes weekly, caches
  the parsed index, and sends "Reel/0.1 (iOS media player; anime title matching)".
- The data is AniDB's; the wiki asks for a credit. Reel's providers page names AniDB.
- The HTTP and UDP APIs need a registered client; Reel does not use them.

## Anime-Lists (fetched: GitHub repository)

- No LICENSE file and no stated licence or usage terms for anime-list-full.xml. It is a community
  mapping derived from AniDB, TheTVDB and TMDB ids, fetched raw from GitHub at runtime.
- Verdict: low practical risk (every anime scraper uses it) but nothing grants the right. Credit it
  on the providers page (done) and open an issue asking the maintainers to state a licence.

## VLCKit

- LGPL 2.1, linked dynamically, licence shown in Settings → About → Licences with the source URL.
  App Store distribution of LGPL frameworks is accepted when they are dynamically linked and the
  app does not restrict the user from replacing the library in ways the licence forbids; this is the
  arrangement VLC for iOS and Infuse rely on. Keep the framework unmodified.

## What to do before submitting

1. Put a TMDB project key, a fanart.tv project key and an OpenSubtitles consumer key into the build
   through a build setting or an ignored file (never in git), with the Settings fields kept as
   overrides.
2. Add the TMDB logo to Settings → About → Data providers.
3. Add a six-month expiry to the metadata and artwork caches.
4. Decide on TheTVDB: keep it user-keyed or remove it.
5. Re-read the OpenSubtitles and AniDB pages in a browser and file copies here (fanart.tv done).
6. Open an issue on Anime-Lists asking for a licence statement.
