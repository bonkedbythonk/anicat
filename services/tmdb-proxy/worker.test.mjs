/**
 * `node --test services/tmdb-proxy/worker.test.mjs`
 *
 * The worker is the only place the TMDB key exists, so the things worth
 * testing are the ones that decide whether it can be spent by somebody else:
 * which paths forward at all, which parameters survive, and that the key is
 * attached the way the credential's own shape requires.
 *
 * `fetch` is stubbed, so this makes no network request and needs no key.
 */
import { test } from "node:test";
import assert from "node:assert/strict";

import worker from "./worker.js";

/** Captures the upstream request the worker would have made. */
function stubFetch() {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push({ url, init });
    return new Response("{}", { status: 200, headers: { "content-type": "application/json" } });
  };
  return calls;
}

const call = (path, key = "0123456789abcdef0123456789abcdef", method = "GET") =>
  worker.fetch(new Request(`https://proxy.example${path}`, { method }), { TMDB_KEY: key });

test("forwards the endpoints the app actually calls", async () => {
  const calls = stubFetch();
  for (const path of [
    "/3/trending/movie/week",
    "/3/tv/popular",
    "/3/movie/550",
    "/3/tv/125988/season/1",
    "/3/search/movie?query=dune",
    "/3/discover/movie?with_genres=28&primary_release_year=1999",
    "/3/genre/tv/list",
    "/3/person/500",
  ]) {
    const response = await call(path);
    assert.equal(response.status, 200, `${path} should forward`);
  }
  assert.equal(calls.length, 8);
});

test("refuses anything else, so it is not an open TMDB account", async () => {
  const calls = stubFetch();
  for (const path of [
    "/3/account/1/favorite",
    "/3/movie/550/lists",
    "/3/person/500/tagged_images",
    "/4/list/1",
    "/",
    "/3/movie/notanumber",
  ]) {
    const response = await call(path);
    assert.equal(response.status, 404, `${path} should be refused`);
  }
  assert.equal(calls.length, 0, "nothing refused should reach TMDB");
});

test("only GET is proxied", async () => {
  const calls = stubFetch();
  const response = await call("/3/movie/550", undefined, "POST");
  assert.equal(response.status, 405);
  assert.equal(calls.length, 0);
});

test("the filter row's parameters survive, the rest still do not", async () => {
  const calls = stubFetch();
  await call("/3/discover/movie?with_genres=28&primary_release_year=1999&sort_by=vote_average.desc&with_people=500");
  const forwarded = new URL(calls[0].url);
  assert.equal(forwarded.searchParams.get("with_genres"), "28");
  assert.equal(forwarded.searchParams.get("primary_release_year"), "1999");
  assert.equal(forwarded.searchParams.get("sort_by"), "vote_average.desc");
  assert.equal(forwarded.searchParams.get("with_people"), null);
});

test("a caller cannot smuggle parameters, or their own key, upstream", async () => {
  const calls = stubFetch();
  await call("/3/search/movie?query=dune&page=2&api_key=theirs&session_id=x&with_people=500");
  const forwarded = new URL(calls[0].url);
  assert.equal(forwarded.searchParams.get("query"), "dune");
  assert.equal(forwarded.searchParams.get("page"), "2");
  assert.equal(forwarded.searchParams.get("session_id"), null);
  // The key on the wire is the proxy's own, never one the caller supplied.
  assert.equal(forwarded.searchParams.get("api_key"), "0123456789abcdef0123456789abcdef");
});

test("adult results cannot be asked for, whatever the caller sent", async () => {
  const calls = stubFetch();
  await call("/3/search/movie?query=x&include_adult=true");
  assert.equal(new URL(calls[0].url).searchParams.get("include_adult"), "false");
});

test("a v4 read token goes in the header and never in the URL", async () => {
  const calls = stubFetch();
  await call("/3/movie/550", "eyJhbGciOiJIUzI1NiJ9.eyJhdWQiOiJhYmMifQ.sig");
  const { url, init } = calls[0];
  assert.equal(new URL(url).searchParams.get("api_key"), null);
  assert.match(init.headers.authorization, /^Bearer eyJ/);
});

test("no key configured is the proxy's failure, not a 404", async () => {
  stubFetch();
  const response = await worker.fetch(
    new Request("https://proxy.example/3/movie/550"),
    {}
  );
  assert.equal(response.status, 500);
});

test("an upstream 429 keeps its Retry-After, which the app backs off on", async () => {
  globalThis.fetch = async () =>
    new Response("{}", { status: 429, headers: { "retry-after": "7" } });
  const response = await call("/3/movie/550");
  assert.equal(response.status, 429);
  assert.equal(response.headers.get("retry-after"), "7");
});
