// Anicat's release mirror: a second place the app and the installer can
// learn what the latest version is and fetch it from, on the same free
// workers.dev subdomain as the TMDB proxy.
//
// Why it exists: the install command, the update check and every release
// asset live on GitHub, and one DMCA notice against the repository takes all
// of them down in the same minute (Hayase's repository has answered HTTP 451
// since 2025-10-23, release assets included). Nothing here hosts content;
// it holds the app's own build artifacts and a JSON file naming them.
//
// Routes, GET and HEAD only:
//   /latest.json         version, tag, page, per-asset sha256/size/url
//   /SHA256SUMS          the release's checksum file
//   /install.sh          the macOS installer, so `curl ... | bash` works
//                        with GitHub unreachable
//   /download/<asset>    the asset from R2 when the bucket is bound and
//                        holds it, else a redirect to the GitHub release
//   /download/SHA256SUMS same file as /SHA256SUMS, at the path the
//                        installers derive from a download URL
//
// State comes from two bindings, both optional at runtime: RELEASES (KV,
// written by scripts/publish-release.sh) and ASSETS (R2, only when the
// account has R2 enabled). Without KV every route 404s; without R2 the
// downloads redirect to GitHub, which is still an improvement for the
// update check but not for a takedown.

const REPO = "bonkedbythonk/anicat";

const KV_FILES = {
  "latest.json": "application/json; charset=utf-8",
  "SHA256SUMS": "text/plain; charset=utf-8",
  "install.sh": "text/plain; charset=utf-8",
};

// Short: publish-release.sh rewrites these on every release and an install
// five minutes later must see the new version, not a day-old edge copy.
const KV_CACHE = "public, max-age=300";
// Long: asset names carry the version, so a name never changes content.
const ASSET_CACHE = "public, max-age=86400, immutable";

// Asset names are what publish-release.sh produces; anything else is not a
// key we hold and must not be forwarded to the origin as a path.
const ASSET_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

function text(body, status = 200, extra = {}) {
  return new Response(body, {
    status,
    headers: { "Content-Type": "text/plain; charset=utf-8", ...extra },
  });
}

async function fromKV(env, key, method) {
  if (!env.RELEASES) return text("mirror not configured\n", 404);
  const value = await env.RELEASES.get(key, { type: "text" });
  if (value === null) return text("not published\n", 404);
  const headers = {
    "Content-Type": KV_FILES[key],
    "Cache-Control": KV_CACHE,
    "Content-Length": String(new TextEncoder().encode(value).byteLength),
  };
  return new Response(method === "HEAD" ? null : value, { status: 200, headers });
}

async function download(env, name, method) {
  if (name === "SHA256SUMS") return fromKV(env, "SHA256SUMS", method);
  if (!ASSET_NAME.test(name)) return text("not found\n", 404);

  if (env.ASSETS) {
    const object = await env.ASSETS.get(name);
    if (object) {
      const headers = {
        "Content-Type": "application/octet-stream",
        "Content-Length": String(object.size),
        "Cache-Control": ASSET_CACHE,
        "ETag": object.httpEtag,
        "Content-Disposition": `attachment; filename="${name}"`,
      };
      return new Response(method === "HEAD" ? null : object.body, { status: 200, headers });
    }
  }

  // Not mirrored (or R2 not enabled): the GitHub release under the tag
  // latest.json names. The installers accept a redirect (`curl -L`,
  // Invoke-WebRequest follows by default).
  const latest = env.RELEASES ? await env.RELEASES.get("latest.json", { type: "json" }) : null;
  const tag = latest && typeof latest.tag === "string" && /^v[0-9][0-9A-Za-z.+-]*$/.test(latest.tag) ? latest.tag : null;
  if (!tag) return text("not published\n", 404);
  return Response.redirect(`https://github.com/${REPO}/releases/download/${tag}/${name}`, 302);
}

export default {
  async fetch(request, env) {
    const method = request.method;
    if (method !== "GET" && method !== "HEAD") {
      return text("method not allowed\n", 405, { Allow: "GET, HEAD" });
    }
    const path = new URL(request.url).pathname;

    if (path === "/") {
      return text("Anicat release mirror: /latest.json, /SHA256SUMS, /install.sh, /download/<asset>\n");
    }
    const kvKey = path.slice(1);
    if (Object.hasOwn(KV_FILES, kvKey)) return fromKV(env, kvKey, method);
    if (path.startsWith("/download/")) {
      let name;
      try {
        name = decodeURIComponent(path.slice("/download/".length));
      } catch {
        return text("not found\n", 404);
      }
      return download(env, name, method);
    }
    return text("not found\n", 404);
  },
};
