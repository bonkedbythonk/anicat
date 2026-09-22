/**
 * `node --test services/release-mirror/worker.test.mjs`
 *
 * The worker is the path that has to work when GitHub does not, so the
 * things worth testing are the ones a takedown would expose: every route
 * with KV alone, the redirect that stands in for R2, and the input checks
 * that keep a request from naming an object we do not hold.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import worker from "./worker.js";

const latest = JSON.stringify({
  version: "1.0.2",
  tag: "v1.0.2",
  page: "https://github.com/bonkedbythonk/anicat/releases/tag/v1.0.2",
  assets: { "Anicat-1.0.2-macos-arm64.zip": { sha256: "ab", size: 3, url: "x" } },
});

function kv(entries) {
  return {
    async get(key, opts) {
      const v = entries[key];
      if (v === undefined) return null;
      return opts && opts.type === "json" ? JSON.parse(v) : v;
    },
  };
}

function r2(objects) {
  return {
    async get(name) {
      const body = objects[name];
      if (body === undefined) return null;
      return { body, size: body.length, httpEtag: '"etag"' };
    },
  };
}

const env = {
  RELEASES: kv({ "latest.json": latest, SHA256SUMS: "ab  Anicat-1.0.2-macos-arm64.zip\n", "install.sh": "#!/bin/bash\n" }),
};

const get = (path, e = env, method = "GET") =>
  worker.fetch(new Request(`https://anicat-releases.anicat.workers.dev${path}`, { method }), e);

test("serves latest.json, SHA256SUMS and install.sh out of KV with short caching", async () => {
  const res = await get("/latest.json");
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("Content-Type"), "application/json; charset=utf-8");
  assert.equal(res.headers.get("Cache-Control"), "public, max-age=300");
  assert.equal((await res.json()).version, "1.0.2");

  assert.equal((await get("/SHA256SUMS")).status, 200);
  assert.equal(await (await get("/install.sh")).text(), "#!/bin/bash\n");
  // The installers derive the checksum URL from the download URL's directory.
  assert.equal(await (await get("/download/SHA256SUMS")).text(), "ab  Anicat-1.0.2-macos-arm64.zip\n");
});

test("HEAD answers headers without a body", async () => {
  const res = await get("/latest.json", env, "HEAD");
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("Content-Length"), String(latest.length));
  assert.equal(await res.text(), "");
});

test("without R2 a download redirects to the GitHub release named by latest.json", async () => {
  const res = await get("/download/Anicat-1.0.2-macos-arm64.zip");
  assert.equal(res.status, 302);
  assert.equal(
    res.headers.get("Location"),
    "https://github.com/bonkedbythonk/anicat/releases/download/v1.0.2/Anicat-1.0.2-macos-arm64.zip",
  );
});

test("with R2 a mirrored download is served, and an unmirrored one still redirects", async () => {
  const e = { ...env, ASSETS: r2({ "Anicat-1.0.2-macos-arm64.zip": "zip" }) };
  const hit = await get("/download/Anicat-1.0.2-macos-arm64.zip", e);
  assert.equal(hit.status, 200);
  assert.equal(hit.headers.get("Content-Length"), "3");
  assert.equal(hit.headers.get("Cache-Control"), "public, max-age=86400, immutable");
  assert.equal(await hit.text(), "zip");

  const miss = await get("/download/Anicat-1.0.2-windows-x64.zip", e);
  assert.equal(miss.status, 302);
});

test("a name that is not an asset name is not forwarded anywhere", async () => {
  const e = { ...env, ASSETS: r2({}) };
  for (const bad of ["/download/a%2Fb", "/download/.hidden", "/download/", "/download/a%2e%2e%2fb"]) {
    const res = await get(bad, e);
    assert.equal(res.status, 404, bad);
  }
  // `..` never reaches the worker as such: the URL parser folds it before
  // routing, so this is the KV file, not a traversal.
  assert.equal((await get("/download/../latest.json", e)).status, 200);
});

test("nothing published, nothing configured, wrong method", async () => {
  assert.equal((await get("/latest.json", {})).status, 404);
  assert.equal((await get("/download/Anicat-1.0.2-macos-arm64.zip", { RELEASES: kv({}) })).status, 404);
  assert.equal((await get("/latest.json", { RELEASES: kv({ "latest.json": '{"tag":"../x"}' }) })).status, 200);
  const res = await get("/download/Anicat-1.0.2-macos-arm64.zip", { RELEASES: kv({ "latest.json": '{"tag":"../x"}' }) });
  assert.equal(res.status, 404);
  assert.equal((await get("/latest.json", env, "POST")).status, 405);
  assert.equal((await get("/nope")).status, 404);
});
