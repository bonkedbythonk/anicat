import { useSettingsStore } from "@/stores/app";

// Per-device playback/display preferences. The server's config.toml is
// global — in multi-user mode a friend flipping autoplay must not change it
// for everyone else — so the phone keeps its own overrides in localStorage
// and layers them on top of whatever loadFromConfig pulled from the server.
const KEY = "anicat_mobile_settings";

export interface MobileSettings {
  defaultProvider?: string;
  autoplay?: boolean;
  autoskip?: boolean;
}

// Sources that are no longer selectable. A device that saved one before it
// was retired would otherwise keep playing from it forever — the picker no
// longer lists it, so there'd be no way to change it from the phone.
const RETIRED_PROVIDERS = ["mkissa", "allanime", "gogoanime", "anizone", "animepahe"];

/** Whether this device can play the "nyaa" (torrent) provider at all.
 *
 * Torrent releases are Matroska: SubsPlease and effectively every Nyaa group
 * ship .mkv, and the proxy serves them as `video/x-matroska`. Chromium demuxes
 * that (H.264/AAC inside), but WebKit has no Matroska demuxer — and every
 * browser on iOS is required to use WebKit, so this is a whole-platform "no",
 * not a Safari-only one. Desktop is unaffected: mpv plays mkv natively and
 * never goes near this code.
 *
 * Feature-detected rather than UA-sniffed. WebKit returns "" from canPlayType
 * for Matroska; Chromium returns "probably".
 */
export function canPlayTorrents(): boolean {
  try {
    const video = document.createElement("video");
    return video.canPlayType('video/x-matroska; codecs="avc1.640028,mp4a.40.2"') !== "";
  } catch {
    return false;
  }
}

export function loadMobileSettings(): MobileSettings {
  try {
    const settings = JSON.parse(window.localStorage.getItem(KEY) || "{}") as MobileSettings;
    if (settings.defaultProvider && RETIRED_PROVIDERS.includes(settings.defaultProvider)) {
      delete settings.defaultProvider;
    }
    // Same reasoning as a retired provider: a device that saved "nyaa" before
    // this check existed (or on another, capable device sharing an account)
    // would otherwise be pinned to a source it can never play, with the
    // picker hidden and no way to switch back.
    if (settings.defaultProvider === "nyaa" && !canPlayTorrents()) {
      delete settings.defaultProvider;
    }
    return settings;
  } catch {
    return {};
  }
}

/** Call after loadFromConfig so device overrides win over server defaults. */
export function applyMobileSettings(): void {
  const overrides = loadMobileSettings();
  const defined = Object.fromEntries(Object.entries(overrides).filter(([, v]) => v !== undefined));
  if (Object.keys(defined).length > 0) {
    useSettingsStore.setState(defined);
  }
}

export function saveMobileSetting<K extends keyof MobileSettings>(key: K, value: MobileSettings[K]): void {
  const settings = loadMobileSettings();
  settings[key] = value;
  window.localStorage.setItem(KEY, JSON.stringify(settings));
  useSettingsStore.setState({ [key]: value });
}
