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

export function loadMobileSettings(): MobileSettings {
  try {
    const settings = JSON.parse(window.localStorage.getItem(KEY) || "{}") as MobileSettings;
    if (settings.defaultProvider && RETIRED_PROVIDERS.includes(settings.defaultProvider)) {
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
