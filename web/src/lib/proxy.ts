import { invoke } from "@tauri-apps/api/core";

const ANILIST_CDN = "s4.anilist.co";

let proxyPort = 13370;
let initialized = false;

export async function initProxyPort(): Promise<void> {
  if (initialized) return;
  initialized = true;
  try {
    proxyPort = await invoke<number>("get_proxy_port");
  } catch {
    proxyPort = 13370;
  }
}

export function proxyImage(url: string | null | undefined): string {
  if (!url) return "";
  if (url.includes(ANILIST_CDN) || url.includes("anilistcdn")) {
    return `http://127.0.0.1:${proxyPort}/proxy?url=${encodeURIComponent(url)}`;
  }
  return url;
}
