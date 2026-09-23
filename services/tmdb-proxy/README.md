# TMDB proxy

A Cloudflare Worker that holds the TMDB key, so the app doesn't ship one. It
only forwards the paths the app uses (`ALLOWED` in `worker.js`, mirroring
`core/src/catalog/cinema.rs`), forces `include_adult=false`, caches at the
edge and limits each IP to 60 searches and 300 requests a minute.

## Deploy

```bash
cd services/tmdb-proxy
npx wrangler login
npx wrangler secret put TMDB_KEY   # v3 key or v4 read token
npx wrangler deploy
```

Build the app against it, and leave `ANICAT_TMDB_KEY` unset or the key ends
up in the bundle again:

```bash
ANICAT_TMDB_PROXY=https://anicat-tmdb.<your-subdomain>.workers.dev \
  bash scripts/package-anicat-macos-app.sh
```

## Check and test

```bash
curl -s "https://anicat-tmdb.<your-subdomain>.workers.dev/3/movie/550" | head -c 200
node --test services/tmdb-proxy/worker.test.mjs
```

## Notes

- A new endpoint in `cinema.rs` needs a matching `ALLOWED` entry, or the
  proxy answers 404.
- `ANICAT_CLIENT_TOKEN` (optional secret) makes the worker refuse requests
  without the app's `x-anicat-client` header. 6.0.0 doesn't send it, so
  leave it unset while that version is still in use.
- If the key is abused, rotate it with `wrangler secret put`; no app release
  needed.
