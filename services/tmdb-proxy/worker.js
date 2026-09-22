/**
 * Anicat's TMDB proxy.
 *
 * The app ships to everyone, so any key inside it is readable by anyone who
 * has it: an Info.plist entry is plain text, a constant in the binary is one
 * `strings` away, and obfuscation only decides how many minutes it takes. The
 * key lives here instead. The app calls this worker with no credential at
 * all, and the only thing an attacker can extract from the app is this URL --
 * which is an endpoint that can be rate limited, revoked and replaced, rather
 * than a credential on the maintainer's TMDB account.
 *
 * Deploy: see README.md. The key is a Wrangler secret named TMDB_KEY; it is
 * never in this file and never in the repo.
 */

/** TMDB paths the app actually calls. Anything else is refused.
 *
 * An open forwarder would be somebody else's free TMDB account within a week,
 * and the account it would be spent from is the maintainer's. The list is
 * exactly `catalog/cinema.rs`'s endpoints -- when a new row or endpoint is
 * added there, it has to be added here too, and the 404 says so.
 */
const ALLOWED = [
  /^\/3\/trending\/(movie|tv)\/(day|week)$/,
  /^\/3\/movie\/(popular|top_rated|upcoming)$/,
  /^\/3\/tv\/(popular|top_rated|on_the_air)$/,
  /^\/3\/movie\/\d{1,9}$/,
  /^\/3\/tv\/\d{1,9}$/,
  /^\/3\/tv\/\d{1,9}\/season\/\d{1,3}$/,
  /^\/3\/search\/(movie|tv)$/,
  /^\/3\/discover\/(movie|tv)$/,
  /^\/3\/genre\/(movie|tv)\/list$/,
  /^\/3\/person\/\d{1,9}$/,
];

/** Query parameters forwarded to TMDB. Everything else is dropped.
 *
 * `api_key` is deliberately absent: a caller must not be able to make this
 * worker forward *their* key, and more importantly must not be able to
 * smuggle parameters that change what the response costs.
 */
const ALLOWED_PARAMS = new Set([
  "language",
  "page",
  "query",
  "include_adult",
  "append_to_response",
  // The filter row: genre, year and sort, as /discover names them.
  "with_genres",
  "primary_release_year",
  "first_air_date_year",
  "sort_by",
]);

/** How long the edge keeps a response.
 *
 * Deliberately close to the app's own TTLs (`cache.rs`: six hours for a row,
 * a day for a detail). The cache is what keeps a thousand installs opening
 * the same trending row from being a thousand requests against one key.
 */
function cacheSeconds(path) {
  if (path.startsWith("/3/search/")) return 600;
  if (/^\/3\/(movie|tv)\/\d/.test(path)) return 86400;
  return 21600;
}

/** Requests per IP per window. */
const LIMITS = {
  search: { name: "search", limit: 60, periodMs: 60_000 },
  any: { name: "any", limit: 300, periodMs: 60_000 },
};

/**
 * One instance per client IP (`idFromName(ip)`), so every request from that
 * address is counted by the same object wherever in the world it lands.
 * Fixed windows kept in memory: an object evicted while idle starts again
 * from zero, which only ever errs towards letting a person through.
 * Plain class with `fetch`, not `extends DurableObject`, so the module has
 * no `cloudflare:workers` import and the tests still run under Node.
 */
export class RateLimiter {
  constructor() {
    this.windows = new Map();
  }

  async fetch(request) {
    const params = new URL(request.url).searchParams;
    const bucket = params.get("bucket") || "any";
    const limit = Number(params.get("limit")) || 300;
    const period = Number(params.get("period")) || 60_000;
    const now = Date.now();
    let window = this.windows.get(bucket);
    if (!window || now - window.start >= period) {
      window = { start: now, count: 0 };
      this.windows.set(bucket, window);
    }
    window.count += 1;
    return new Response(null, { status: window.count > limit ? 429 : 204 });
  }
}

function deny(status, message) {
  return new Response(JSON.stringify({ status_message: message }), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export default {
  async fetch(request, env, ctx) {
    if (request.method !== "GET") {
      return deny(405, "Only GET is proxied.");
    }
    if (!env.TMDB_KEY) {
      return deny(500, "The proxy has no TMDB key configured.");
    }

    const url = new URL(request.url);
    if (!ALLOWED.some((pattern) => pattern.test(url.pathname))) {
      return deny(404, "Not a proxied TMDB endpoint.");
    }

    // Per-IP limits, before anything reaches TMDB. The URL is public (it is
    // in every build and in this repo), and until this there was nothing
    // between a script that found it and the one TMDB key every install
    // shares. Search is limited hardest: it is cached for ten minutes where
    // a row is cached for hours, so it is the path that turns requests into
    // upstream calls. The limits are generous for a person (a home screen is
    // eight rows, a cinema search two requests).
    //
    // Counted by `RateLimiter`, one Durable Object per IP, not Cloudflare's
    // rate-limit binding: that binding was deployed first and never refused
    // anything on this account, not even at a limit of one request per ten
    // seconds (five in a row, all answered, 2026-09-22). No binding (the
    // tests, a deploy without it) means no limit rather than an outage.
    const ip = request.headers.get("cf-connecting-ip") || "unknown";
    const isSearch = url.pathname.startsWith("/3/search/");
    if (env.LIMITER) {
      const bucket = isSearch ? LIMITS.search : LIMITS.any;
      const stub = env.LIMITER.get(env.LIMITER.idFromName(ip));
      const verdict = await stub.fetch(
        `https://limiter/hit?bucket=${bucket.name}&limit=${bucket.limit}&period=${bucket.periodMs}`,
      );
      if (verdict.status === 429) {
        // The app's TMDB client parks every caller for the Retry-After it
        // names (catalog/tmdb/client.rs), so this slows it rather than
        // breaking a page.
        return new Response(JSON.stringify({ status_message: "Too many requests." }), {
          status: 429,
          headers: { "content-type": "application/json", "retry-after": "60" },
        });
      }
    }

    // The app sends `x-anicat-client`; nothing else does. It is not a secret
    // -- it ships in a public repo and inside every build -- so it proves
    // nothing about who is calling. What it does is separate traffic that
    // came from Anicat from traffic that found this URL, which is what makes
    // a rate limit or an outright refusal possible at all.
    //
    // Enforced only when ANICAT_CLIENT_TOKEN is set, and left unset until no
    // release that predates the header is still in use: turning it on early
    // takes cinema mode away from installs that cannot send it, and they
    // would see the same silent empty shelves this whole arrangement exists
    // to avoid.
    if (env.ANICAT_CLIENT_TOKEN) {
      if (request.headers.get("x-anicat-client") !== env.ANICAT_CLIENT_TOKEN) {
        return deny(403, "Not an Anicat client.");
      }
    }

    const upstream = new URL(`https://api.themoviedb.org${url.pathname}`);
    for (const [key, value] of url.searchParams) {
      if (ALLOWED_PARAMS.has(key)) upstream.searchParams.set(key, value);
    }
    // Never let a caller ask for adult results, whatever they sent: the app
    // sends include_adult=false and TMDB's terms forbid using their API with
    // obscene or pornographic content.
    upstream.searchParams.set("include_adult", "false");

    // A v4 read token is a JWT and goes in the header; a v3 key is a
    // 32-character hex string and goes in the query string. Same shape test
    // the app uses, for the same reason: TMDB hands out both without saying
    // they authenticate differently.
    const isV4 = env.TMDB_KEY.startsWith("eyJ");
    if (!isV4) upstream.searchParams.set("api_key", env.TMDB_KEY);

    const ttl = cacheSeconds(url.pathname);
    const response = await fetch(upstream.toString(), {
      headers: {
        ...(isV4 ? { authorization: `Bearer ${env.TMDB_KEY}` } : {}),
        // TMDB's terms forbid concealing who is calling.
        "user-agent": "Anicat-Proxy (+https://github.com/bonkedbythonk/anicat)",
        accept: "application/json",
      },
      cf: { cacheTtl: ttl, cacheEverything: true },
    });

    const body = await response.text();
    return new Response(body, {
      status: response.status,
      headers: {
        "content-type": "application/json",
        // Passed through so the app's own backoff has something to obey; a
        // 429 upstream must not read to the app as a proxy failure.
        ...(response.headers.get("retry-after")
          ? { "retry-after": response.headers.get("retry-after") }
          : {}),
        "cache-control": `public, max-age=${ttl}`,
      },
    });
  },
};
