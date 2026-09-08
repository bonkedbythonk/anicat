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
thing the proxy exists to avoid.

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

Anyone with a copy of the app has the URL, so treat it as public. Two things
worth setting in the Cloudflare dashboard once it is live:

- **Rate limiting rule** on the worker's route -- something like 60 requests
  per minute per IP is far above what one person browsing can produce and far
  below what a scraper wants.
- **Alerts** on request volume, so a spike is something you hear about rather
  than something TMDB tells you about.

If it is ever abused badly, rotating the secret costs one `wrangler secret
put` and no app release. That is the difference from a key inside the app,
which needs everyone to update.

## When the app calls something new

`ALLOWED` in `worker.js` mirrors `core/src/catalog/cinema.rs`. A new endpoint
there without a matching entry here answers 404 -- deliberately, since the
alternative is an open forwarder spending your key on whatever anyone asks.
