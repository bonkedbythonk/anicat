const ANILIST_CDN = "s4.anilist.co";
const PROXY_BASE = "http://127.0.0.1:13370/proxy";

export function proxyImage(url: string | null | undefined): string {
  if (!url) return "";
  if (url.includes(ANILIST_CDN) || url.includes("anilistcdn")) {
    return `${PROXY_BASE}?url=${encodeURIComponent(url)}`;
  }
  return url;
}
