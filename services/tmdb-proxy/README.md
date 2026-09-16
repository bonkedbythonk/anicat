# Anicat's TMDB proxy

The app ships to everyone, so a TMDB key inside it belongs to everyone: an
`Info.plist` entry is plain text (`plutil -p Anicat.app/Contents/Info.plist`),
a constant in the binary is one `strings` away, and obfuscating it only
decides how many minutes the extraction takes. This worker is where the key
lives instead. The app calls it with no credential at all, so the only thing
recoverable from a copy of the app is this URL -- an endpoint that can be rate
limited, rotated or replaced, rather than a credential on your TMDB account.

It is a forwarder and nothing else: no database, no state, no user data. It
refuses every path the app does not call (`worker.js`'s `ALLOWED`), drops
every query parameter the app does not send, forces `include_adult=false`, and
passes an upstream `Retry-After` back so the app's own backoff can obey it.

## Deploy

```bash
cd services/tmdb-proxy
npx wrangler login
npx wrangler secret put TMDB_KEY   # paste a v3 key or a v4 read token
npx wrangler deploy
```

`deploy` prints the URL (`https://anicat-tmdb.<your-subdomain>.workers.dev`).
Build the app against it:

```bash
ANICAT_TMDB_PROXY=https://anicat-tmdb.<your-subdomain>.workers.dev \
  bash scripts/package-anicat-macos-app.sh
```

That is the whole wiring. `ANICAT_TMDB_KEY` is then unnecessary and should be
left unset: with both set the key would ship in the bundle again, which is the
thing the proxy exists to avoid. The URL of the deployed worker is committed
(`AnicatApple/project.yml`, and the default in the packaging script), because
it ships inside every build anyway -- `plutil -p` on any `.app` prints it --
and a build that has to be told the URL is a build that silently loses cinema
mode when someone forgets.

## Check it works

```bash
curl -s "https://anicat-tmdb.<your-subdomain>.workers.dev/3/movie/550" | head -c 200
curl -s -o /dev/null -w '%{http_code}\n' "https://anicat-tmdb.<your-subdomain>.workers.dev/3/person/500"   # 404, refused
```

## Tests

```bash
node --test services/tmdb-proxy/worker.test.mjs
```

No network and no key required -- `fetch` is stubbed, and what is tested is
which paths forward, which parameters survive, and that the key is attached
the way its own shape requires.

## Limiting abuse

Anyone with a copy of the app has the URL, so treat it as public -- it is
committed here and in `AnicatApple/project.yml` for that reason, since a build
that has to be told the URL is a build that silently loses cinema mode when
someone forgets. Three things guard the quota, in the order they matter.

**The edge cache, already on.** Rows live six hours, a detail a day, a search
ten minutes (`cacheSeconds`). A thousand installs opening Trending is a handful
of requests upstream, so ordinary use barely touches the key. High-cardinality
traffic -- a scraper walking search terms -- is what produces misses, and what
the other two are for.

**A rate-limiting rule and a usage alert**, both in the Cloudflare dashboard;
nothing in this repo can set them. Security > WAF > Rate limiting rules on this
worker's route, something like 120 requests per minute per IP: the app makes
eight requests to fill a home page and then sits on its own cache, so a real
user never approaches it. Check what your plan includes rather than assuming.
The alert matters just as much -- the free plan stops at 100k requests a day
and the first symptom is Films and TV going empty for everybody.

**`ANICAT_CLIENT_TOKEN`, which is off until you set it.** The app sends
`x-anicat-client: anicat` with every proxied request; set the variable to that
value and the worker refuses anything without it:

```bash
npx wrangler secret put ANICAT_CLIENT_TOKEN   # the value the app sends
```

It is not a credential and cannot be -- it is in this repo and in every binary
-- so it stops somebody who found the URL, not somebody who read the source.
**Do not set it while a release that predates the header is still in use.**
6.0.0 does not send it, and those installs would lose cinema mode with no
message at all, which is the failure this whole arrangement exists to avoid.
Unset, the worker serves everyone exactly as it did before.

If it is ever abused badly, rotating the TMDB key costs one `wrangler secret
put` and no app release. That is the difference from a key inside the app,
which needs everyone to update.

## When the app calls something new

`ALLOWED` in `worker.js` mirrors `core/src/catalog/cinema.rs`. A new endpoint
there without a matching entry here answers 404 -- deliberately, since the
alternative is an open forwarder spending your key on whatever anyone asks.
