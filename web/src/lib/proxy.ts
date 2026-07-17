import { invoke, convertFileSrc } from "@tauri-apps/api/core";
import { isTauri } from "./transport";

const ANILIST_CDN = "s4.anilist.co";

let proxyPort = 13370;
let initialized = false;

export async function initProxyPort(): Promise<void> {
  if (initialized) return;
  initialized = true;
  // The mobile PWA is served by the same process that owns /proxy, so it
  // never needs to know the port — apiOrigin() below just uses a relative
  // URL. get_proxy_port is a desktop-only Tauri command with no mobile-api
  // equivalent (there's nothing to look up on that side).
  if (!isTauri()) return;
  try {
    proxyPort = await invoke<number>("get_proxy_port");
  } catch {
    proxyPort = 13370;
  }
}

/** Origin to prefix proxy/API URLs with. Desktop's Tauri webview has its own
 * origin (not the proxy server's), so it needs the absolute 127.0.0.1 form;
 * the mobile PWA is served BY the proxy server itself, so a relative URL
 * already resolves to whatever LAN IP the phone loaded the page from. */
export function apiOrigin(): string {
  return isTauri() ? `http://127.0.0.1:${proxyPort}` : "";
}

export function proxyImage(url: string | null | undefined): string {
  if (!url) return "";
  if (url.includes(ANILIST_CDN) || url.includes("anilistcdn")) {
    return `${apiOrigin()}/proxy?url=${encodeURIComponent(url)}`;
  }
  // Convert local absolute paths to asset:// protocol so Tauri can load them
  if (isTauri() && (url.startsWith("/") || /^[a-zA-Z]:\\/.test(url))) {
    return convertFileSrc(url);
  }
  return url;
}
