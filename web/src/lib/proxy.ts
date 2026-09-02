import { invoke, convertFileSrc } from "@tauri-apps/api/core";
import { isTauri, apiOrigin, setProxyPort } from "./transport";

const ANILIST_CDN = "s4.anilist.co";

let initialized = false;

export async function initProxyPort(): Promise<void> {
  if (initialized) return;
  initialized = true;
  if (!isTauri()) return;
  try {
    const port = await invoke<number>("get_proxy_port");
    setProxyPort(port);
  } catch {
    setProxyPort(13370);
  }
}

export { apiOrigin };

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
