
import React, { useState, useEffect, useRef, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { Loader2, CheckCircle2, Save, Cpu, PlayCircle, HardDrive, Globe, RotateCcw, XCircle, AlertCircle, Download, Copy } from "lucide-react";
import { mediaApi, type HealthStatus, apiOrigin, dispatchRefresh } from "@/lib/api";
import { useAppStore, useSettingsStore } from "@/stores/app";
import type { UiStyle } from "@/hooks/useTheme";
import { ErrorBanner } from "@/components/ErrorBanner";

interface SettingsViewProps {
  health: HealthStatus | null;
}

export function SettingsView({ health }: SettingsViewProps) {
  const apiConnected = useAppStore((s) => s.apiConnected);
  const apiAuthenticated = useAppStore((s) => s.apiAuthenticated);
  const authError = useAppStore((s) => s.authError);
  const tokenPresent = useAppStore((s) => s.tokenPresent);
  const [config, setConfig] = useState<Record<string, Record<string, unknown>> | null>(null);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);
  const [activeTab, setActiveTab] = useState<"general" | "player" | "account" | "maintenance">("general");

  // Read default tab from store (set by Connect button on HomeView)
  useEffect(() => {
    const tab = useAppStore.getState().settingsDefaultTab;
    if (tab === "account" || tab === "maintenance") {
      setActiveTab(tab);
      useAppStore.getState().setSettingsDefaultTab(null);
    }
  }, []);
  const [backingUp, setBackingUp] = useState(false);
  const [backupUrl, setBackupUrl] = useState<string | null>(null);
  const [checkingUpdate, setCheckingUpdate] = useState(false);
  const [stagedHasUpdate, setStagedHasUpdate] = useState(health?.update_available || false);
  const [updateMessage, setUpdateMessage] = useState<{ text: string; type: "success" | "error" | null }>({ text: "", type: null });
  const [releaseNotes, setReleaseNotes] = useState<string>("");
  const [releaseUrl, setReleaseUrl] = useState<string>("");
  const [authPending, setAuthPending] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  const [theme, setTheme] = useState<"system" | "dark" | "light">("system");
  const [uiStyle, setUiStyle] = useState<UiStyle>("ink-and-index");
  const [logoutState, setLogoutState] = useState<"idle" | "confirming" | "loggingOut">("idle");
  const [registryState, setRegistryState] = useState<"idle" | "confirming" | "wiping" | "done">("idle");
  const [resetOnboardingState, setResetOnboardingState] = useState<"idle" | "confirming">("idle");
  const [debugBusy, setDebugBusy] = useState(false);
  const [debugResult, setDebugResult] = useState<{ ok: boolean; summary: string; raw: string } | null>(null);
  const debugNameRef = useRef<HTMLInputElement>(null);
  const debugEpisodeRef = useRef<HTMLInputElement>(null);
  const debugProviderRef = useRef<HTMLSelectElement>(null);

  // Provider test: resolve the first search match, ask the backend to fetch
  // streams for the given episode, and report a clean pass/fail. The full raw
  // response is kept only behind a copy button for bug reports.
  const runProviderTest = useCallback(async () => {
    const name = debugNameRef.current?.value?.trim();
    const ep = parseInt(debugEpisodeRef.current?.value || "1", 10) || 1;
    const provider = debugProviderRef.current?.value || "mkissa";
    if (!name) return;
    setDebugBusy(true);
    setDebugResult(null);
    try {
      const res = await mediaApi.search(name, "ANIME", 1);
      const first = res?.media?.[0];
      if (!first?.id) {
        setDebugResult({ ok: false, summary: `No anime found for "${name}".`, raw: "" });
        return;
      }
      const title = first.title?.english || first.title?.romaji || name;
      const data = await invoke<Record<string, unknown>>("debug_provider_streams", {
        mediaId: first.id,
        episodeNumber: ep,
        provider,
      });
      const streams = (data?.final_streams as unknown[]) || [];
      const errors = (data?.errors as string[]) || [];
      const ok = streams.length > 0;
      const summary = ok
        ? `${streams.length} stream${streams.length === 1 ? "" : "s"} found for ${title} episode ${ep} on ${provider}.`
        : `No streams found for ${title} episode ${ep} on ${provider}.${errors.length ? ` First error: ${errors[0]}` : ""}`;
      setDebugResult({ ok, summary, raw: JSON.stringify(data, null, 2) });
    } catch (err) {
      setDebugResult({ ok: false, summary: "Test failed: " + String(err), raw: "" });
    } finally {
      setDebugBusy(false);
    }
  }, []);

  const hasUpdate = Boolean(health?.update_available || stagedHasUpdate);

  useEffect(() => {
    if (typeof window !== "undefined") {
      const savedTheme = localStorage.getItem("anicat_theme") as "system" | "dark" | "light" | null;
      const savedStyle = localStorage.getItem("anicat_ui_style") as UiStyle | null;
      if (savedTheme) {
        setTheme(savedTheme);
      }
      if (savedStyle) {
        setUiStyle(savedStyle);
      }
    }
  }, []);

  const handleThemeChange = (newTheme: "system" | "dark" | "light") => {
    document.documentElement.classList.add("theme-transition");

    setTheme(newTheme);
    localStorage.setItem("anicat_theme", newTheme);

    const isDarkSystem = window.matchMedia('(prefers-color-scheme: dark)').matches;
    document.documentElement.classList.remove('light', 'dark', 'system');
    document.documentElement.classList.add(newTheme);
    if (newTheme === 'light' || (newTheme === 'system' && !isDarkSystem)) {
      document.documentElement.classList.add('light');
    } else {
      document.documentElement.classList.add('dark');
    }
    window.dispatchEvent(new StorageEvent('storage', { key: 'anicat_theme', newValue: newTheme }));

    setTimeout(() => {
      document.documentElement.classList.remove("theme-transition");
    }, 300);
  };

  const handleStyleChange = (newStyle: UiStyle) => {
    document.documentElement.classList.add("theme-transition");

    // Apply immediately — don't wait for the StorageEvent roundtrip
    document.documentElement.setAttribute("data-style", newStyle);
    if (newStyle === "sakura-zen") {
      if (!document.getElementById("font-noto-serif-jp")) {
        const link = document.createElement("link");
        link.id = "font-noto-serif-jp";
        link.rel = "stylesheet";
        link.href = "https://fonts.googleapis.com/css2?family=Noto+Serif+JP:wght@400;600;700&display=swap";
        document.head.appendChild(link);
      }
    } else if (newStyle === "retro-manga") {
      if (!document.getElementById("font-retro-manga")) {
        const link = document.createElement("link");
        link.id = "font-retro-manga";
        link.rel = "stylesheet";
        link.href = "https://fonts.googleapis.com/css2?family=Bangers&family=Noto+Sans+JP:wght@400;700&display=swap";
        document.head.appendChild(link);
      }
    }

    setUiStyle(newStyle);
    localStorage.setItem("anicat_ui_style", newStyle);
    window.dispatchEvent(new StorageEvent("storage", { key: "anicat_ui_style", newValue: newStyle }));
    setTimeout(() => {
      document.documentElement.classList.remove("theme-transition");
    }, 300);
  };

  const [logsText, setLogsText] = useState<string>("Loading logs...");

  useEffect(() => {
    if (activeTab === "maintenance") {
      setLogsText("Loading logs...");
      mediaApi.getLogs(100)
        .then((res) => {
          setLogsText(res.logs || "No logs available.");
        })
        .catch((err) => {
          setLogsText(`Failed to load logs: ${err}`);
        });
    }
  }, [activeTab]);

  useEffect(() => {
    mediaApi.getConfig()
      .then(setConfig)
      .catch(console.error)
      .finally(() => setLoading(false));

  }, []);

  // The ctrl+1 (upscaling) / ctrl+2 (auto-skip) mpv shortcuts persist their
  // flip on the backend, but this page's own `config` snapshot was fetched
  // once on mount — patch it live so the toggles here don't show stale state
  // if Settings happens to be open while mpv is playing.
  useEffect(() => {
    const unlisten = listen<{ key: string; value: boolean | string }>("anicat_setting_toggled", (event) => {
      const { key, value } = event.payload;
      setConfig((prev) => {
        if (!prev) return prev;
        if (key === "autoskip") {
          return { ...prev, general: { ...prev.general, autoskip: value } };
        }
        if (key === "autoplay") {
          return { ...prev, general: { ...prev.general, autoplay: value } };
        }
        if (key === "shader_profile") {
          return { ...prev, stream: { ...prev.stream, shader_profile: value } };
        }
        return prev;
      });
    });
    return () => { unlisten.then((fn) => fn()); };
  }, []);

  const handleOpenLogs = async () => {
    try {
      await invoke("open_logs_folder");
    } catch (err) {
      console.error("Failed to open logs:", err);
      setErrorMessage("Could not open logs folder automatically.");
      setTimeout(() => setErrorMessage(null), 6000);
    }
  };

  const handleUpdate = async () => {
    setCheckingUpdate(true);
    setUpdateMessage({ text: "", type: null });
    setReleaseNotes("");
    setReleaseUrl("");
    try {
      if (!hasUpdate) {
        // If we don't know of an update yet, check for one first!
        const res = await mediaApi.checkUpdate();
        if (res.status === "success") {
          setStagedHasUpdate(res.update_available ?? false);
          setUpdateMessage({ text: res.message, type: "success" });
          if (res.release_notes) setReleaseNotes(res.release_notes);
          if (res.release_url) setReleaseUrl(res.release_url);
        } else {
          setUpdateMessage({ text: res.message, type: "error" });
        }
      } else {
        // If we already know there is an update, trigger the installation!
        const res = await mediaApi.triggerUpdate();
        if (res.status === "success") {
          setStagedHasUpdate(false);
          // On Windows the backend exits the app itself once the silent NSIS
          // installer is launched (installers can't overwrite a running
          // exe), and a silent install doesn't relaunch the app afterward —
          // unlike macOS, there is nothing to reopen automatically here.
          if (window.navigator.platform.includes("Win")) {
            setUpdateMessage({ text: "Anicat is closing to finish installing the update. Reopen it in a moment.", type: "success" });
          } else {
            setUpdateMessage({ text: "Update installed. Relaunching...", type: "success" });
            setTimeout(() => invoke("relaunch_app").catch(console.error), 1500);
          }
        } else {
          setUpdateMessage({ text: res.message, type: "error" });
        }
      }
    } catch (err) {
      console.error("Update failed:", err);
      setUpdateMessage({ text: "Something went wrong while checking for updates. Please try again.", type: "error" });
    } finally {
      setCheckingUpdate(false);
    }
  };

  // Auto-save with debounce — saves 800ms after the last change
  const autoSaveTimerRef = useRef<NodeJS.Timeout | null>(null);
  const autoSave = useCallback((partialConfig: Record<string, Record<string, unknown>>) => {
    if (autoSaveTimerRef.current) clearTimeout(autoSaveTimerRef.current);
    autoSaveTimerRef.current = setTimeout(async () => {
      setSaving(true);
      try {
        await mediaApi.updateConfig(partialConfig);
        setSaved(true);
        setTimeout(() => setSaved(false), 2000);
      } catch (err) {
        console.error("Auto-save failed:", err);
        setErrorMessage("Failed to save. Try again.");
        setTimeout(() => setErrorMessage(null), 4000);
      } finally {
        setSaving(false);
      }
    }, 800);
  }, []);

  const updateField = (section: string, field: string, value: unknown) => {
    setConfig(prev => {
      if (!prev) return null;
      return {
        ...prev,
        [section]: { ...prev[section], [field]: value }
      };
    });
    autoSave({ [section]: { [field]: value } });
  };

  const handleBackup = async () => {
    setBackingUp(true);
    setBackupUrl(null);
    try {
      await mediaApi.triggerBackup();
      setBackupUrl(`${apiOrigin()}/api/registry/backup/download`);
    } finally {
      setBackingUp(false);
    }
  };

  if (loading || !config) {
    return (
      <div className="flex items-center justify-center h-full">
        <Loader2 className="animate-spin text-accent" size={36} />
      </div>
    );
  }

  const tabs = [
    { id: "general", label: "General", icon: Cpu },
    { id: "player", label: "Player", icon: PlayCircle },
    { id: "account", label: "Account", icon: Globe },
    { id: "maintenance", label: "Maintenance", icon: RotateCcw },
  ] as const;

  return (
    <div className="space-y-8 animate-fade-in max-w-6xl">
      {successMessage && (
        <div className="flex items-center space-x-3 px-5 py-3.5 rounded-lg bg-green-500/10 border border-green-500/20 text-green-400 font-bold text-sm animate-fade-in shadow-lg">
          <CheckCircle2 size={18} />
          <span>{successMessage}</span>
          <button onClick={() => setSuccessMessage(null)} className="ml-auto p-1 hover:bg-green-500/10 rounded-lg transition-colors">
            <XCircle size={16} />
          </button>
        </div>
      )}
      {errorMessage && <ErrorBanner message={errorMessage} />}
      <div className="flex items-end justify-between">
        <div>
          <h1 className="text-[22px] font-semibold tracking-tight text-foreground">Settings</h1>
          <p className="text-[13px] text-muted-foreground mt-0.5">Configure playback, appearance, and account</p>
        </div>
        <div className="flex items-center space-x-2">
          {saving && (
            <div className="flex items-center space-x-1.5 text-xs text-muted-foreground font-medium">
              <Loader2 size={12} className="animate-spin" />
              <span>Saving...</span>
            </div>
          )}
          {saved && (
            <div className="flex items-center space-x-1.5 text-xs text-green-500 font-medium animate-fade-in">
              <CheckCircle2 size={12} />
              <span>Saved</span>
            </div>
          )}
        </div>
      </div>

      <div className="flex flex-col lg:flex-row gap-8">
        {/* Vertical nav rail — full-height settings layout */}
        <nav className="lg:w-56 shrink-0">
          <div className="lg:sticky lg:top-2 flex lg:flex-col gap-1 overflow-x-auto scrollbar-hide p-0.5">
            {tabs.map((tab) => (
              <button
                key={tab.id}
                onClick={() => setActiveTab(tab.id)}
                className={`flex items-center gap-2.5 px-4 py-2 rounded-md font-medium text-[13px] whitespace-nowrap transition-all justify-center lg:w-full lg:justify-start ${
                  activeTab === tab.id
                    ? "bg-foreground/[0.07] text-foreground font-semibold"
                    : "text-muted-foreground hover:text-foreground hover:bg-foreground/[0.03]"
                }`}
              >
                <tab.icon size={18} />
                <span>{tab.label}</span>
              </button>
            ))}
          </div>
        </nav>

        {/* Settings form */}
        <div className="flex-1 min-w-0 space-y-6">
          {activeTab === "general" && (
            <div className="space-y-6 animate-fade-in">
              <CardSection title="Appearance">
                <SettingField
                  label="Theme"
                  description="Choose your preferred visual theme."
                >
                  <select
                    value={theme}
                    onChange={(e) => handleThemeChange(e.target.value as "system" | "dark" | "light")}
                    className="w-full sm:w-auto sm:min-w-[160px] bg-surface border border-border rounded-lg px-3 py-1.5 text-[13px] font-medium focus:border-accent outline-none transition-all appearance-none cursor-pointer text-foreground"
                  >
                    <option value="system">System Default</option>
                    <option value="dark">Dark</option>
                    <option value="light">Light</option>
                  </select>
                </SettingField>

                <SettingField
                  label="Style"
                  description="Choose a complete visual skin for the interface."
                  stack
                >
                  <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3">
                    {/* Ink & Index */}
                    <button
                      onClick={() => handleStyleChange("ink-and-index")}
                      className={`group relative rounded-lg overflow-hidden border-2 transition-all text-left ${
                        uiStyle === "ink-and-index"
                          ? "border-accent shadow-sm"
                          : "border-border hover:border-foreground/25"
                      }`}
                    >
                      <div className="h-20 w-full" style={{ background: "linear-gradient(135deg, #161310 0%, #1e1a15 60%, #252015 100%)" }}>
                        <div className="flex gap-1.5 p-2.5 h-full items-end">
                          <div className="flex-1 h-8 rounded-md" style={{ background: "#1e1a15", border: "1px solid rgba(255,255,255,0.05)" }} />
                          <div className="flex-1 h-8 rounded-md" style={{ background: "rgba(143,184,220,0.3)", border: "1px solid rgba(143,184,220,0.4)" }} />
                        </div>
                      </div>
                      <div className="px-3 py-2 h-14 flex flex-col justify-center bg-surface">
                        <div className="text-xs font-bold text-foreground">Ink & Index</div>
                        <div className="text-[10px] text-muted-foreground mt-0.5">Warm ink / Indigo accent</div>
                      </div>
                      {uiStyle === "ink-and-index" && (
                        <div className="absolute top-2 right-2 w-4 h-4 rounded-full bg-accent flex items-center justify-center">
                          <svg width="8" height="8" viewBox="0 0 8 8" fill="none"><path d="M1 4l2 2 4-4" stroke="var(--dynamic-black)" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/></svg>
                        </div>
                      )}
                    </button>

                    {/* Sakura Zen */}
                    <button
                      onClick={() => handleStyleChange("sakura-zen")}
                      className={`group relative rounded-lg overflow-hidden border-2 transition-all text-left ${
                        uiStyle === "sakura-zen"
                          ? "border-accent shadow-sm"
                          : "border-border hover:border-foreground/25"
                      }`}
                    >
                      <div className="h-20 w-full" style={{ background: "linear-gradient(135deg, #130910 0%, #1a0e14 60%, #1f1018 100%)" }}>
                        <div className="flex gap-1.5 p-2.5 h-full items-end">
                          <div className="flex-1 h-8 rounded-md" style={{ background: "rgba(244,180,196,0.08)", border: "1px solid rgba(232,160,180,0.2)" }} />
                          <div className="flex-1 h-8 rounded-md" style={{ background: "rgba(232,160,180,0.25)", border: "1px solid rgba(232,160,180,0.4)" }} />
                        </div>
                      </div>
                      <div className="px-3 py-2 h-14 flex flex-col justify-center bg-surface">
                        <div className="text-xs font-bold text-foreground">Sakura Zen</div>
                        <div className="text-[10px] text-muted-foreground mt-0.5">Soft pastel / Japanese editorial</div>
                      </div>
                      {uiStyle === "sakura-zen" && (
                        <div className="absolute top-2 right-2 w-4 h-4 rounded-full bg-accent flex items-center justify-center">
                          <svg width="8" height="8" viewBox="0 0 8 8" fill="none"><path d="M1 4l2 2 4-4" stroke="var(--dynamic-black)" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/></svg>
                        </div>
                      )}
                    </button>

                    {/* Retro Manga */}
                    <button
                      onClick={() => handleStyleChange("retro-manga")}
                      className={`group relative rounded-lg overflow-hidden border-2 transition-all text-left ${
                        uiStyle === "retro-manga"
                          ? "border-accent shadow-sm"
                          : "border-border hover:border-foreground/25"
                      }`}
                    >
                      <div className="h-20 w-full" style={{ background: "linear-gradient(135deg, #191410 0%, #241e17 100%)" }}>
                        <div className="flex gap-1.5 p-2.5 h-full items-end">
                          <div className="flex-1 h-8 rounded" style={{ background: "#ede8e0", border: "3px solid #0c0a08" }} />
                          <div className="flex-1 h-8 rounded" style={{ background: "#c02024", border: "2px solid #0c0a08" }} />
                        </div>
                      </div>
                      <div className="px-3 py-2 h-14 flex flex-col justify-center bg-surface">
                        <div className="text-xs font-bold text-foreground">Retro Manga</div>
                        <div className="text-[10px] text-muted-foreground mt-0.5">Halftone dot / Manga panel style</div>
                      </div>
                      {uiStyle === "retro-manga" && (
                        <div className="absolute top-2 right-2 w-4 h-4 rounded-full bg-accent flex items-center justify-center">
                          <svg width="8" height="8" viewBox="0 0 8 8" fill="none"><path d="M1 4l2 2 4-4" stroke="var(--dynamic-black)" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/></svg>
                        </div>
                      )}
                    </button>
                  </div>
                </SettingField>



                <SettingField
                  label="Time Format"
                  description="How dates and times should be displayed."
                >
                  <select
                    value={String(config.general?.time_format || "12h")}
                    onChange={(e) => {
                      const format = e.target.value;
                      updateField("general", "time_format", format);
                      // ScheduleView's airing times read this key directly
                      // (localStorage, set during onboarding) rather than the
                      // config this toggle actually writes — without also
                      // updating it here, the Schedule tab's AM/PM display
                      // never changed no matter what you picked.
                      localStorage.setItem("anicat_time_format", format);
                    }}
                    className="w-full sm:w-auto sm:min-w-[160px] bg-surface border border-border rounded-lg px-3 py-1.5 text-[13px] font-medium focus:border-accent outline-none transition-all appearance-none cursor-pointer text-foreground"
                  >
                    <option value="12h">12-hour (AM/PM)</option>
                    <option value="24h">24-hour</option>
                  </select>
                </SettingField>

              </CardSection>

              <CardSection title="Advanced" description="Rarely need to change these after initial setup.">
                <SettingField label="Discord Rich Presence" description="Show current anime in your Discord status.">
                  <SettingToggle
                    on={Boolean(config.general?.discord)}
                    onChange={(v) => updateField("general", "discord", v)}
                  />
                </SettingField>

                <SettingField label="Download Location" description="Where downloaded episodes are saved.">
                  <div className="relative">
                    <HardDrive size={16} className="absolute left-4 top-1/2 -translate-y-1/2 text-muted-foreground" />
                    <input
                      type="text"
                      value={String(config.general?.downloads_path || "")}
                      onChange={(e) => updateField("general", "downloads_path", e.target.value)}
                      className="w-full bg-transparent border border-border rounded-md py-3.5 pl-11 pr-4 text-sm font-medium focus:border-accent outline-none transition-all"
                    />
                  </div>
                </SettingField>

                <SettingField label="Anime Provider" description="Primary streaming source.">
                  <select
                    value={String(config.general?.provider || "nyaa")}
                    onChange={(e) => updateField("general", "provider", e.target.value)}
                    className="w-full sm:w-auto sm:min-w-[160px] bg-surface border border-border rounded-lg px-3 py-1.5 text-[13px] font-medium focus:border-accent outline-none transition-all appearance-none cursor-pointer text-foreground"
                  >
                    <option value="nyaa">Torrents</option>
                    <option value="mkissa">Mkissa</option>
                    <option value="anineko">AniNeko</option>
                  </select>
                </SettingField>

                <SettingField label="Fallback Provider 1" description="First fallback when primary provider fails.">
                  <select
                    value={String(config.general?.fallback_provider || "mkissa")}
                    onChange={(e) => updateField("general", "fallback_provider", e.target.value)}
                    className="w-full sm:w-auto sm:min-w-[160px] bg-surface border border-border rounded-lg px-3 py-1.5 text-[13px] font-medium focus:border-accent outline-none transition-all appearance-none cursor-pointer text-foreground"
                  >
                    <option value="none">None</option>
                    <option value="nyaa">Torrents</option>
                    <option value="mkissa">Mkissa</option>
                    <option value="anineko">AniNeko</option>
                  </select>
                </SettingField>

                <SettingField label="Fallback Provider 2" description="Second fallback when primary and fallback 1 fail.">
                  <select
                    value={String(config.general?.secondary_fallback_provider || "anineko")}
                    onChange={(e) => updateField("general", "secondary_fallback_provider", e.target.value)}
                    className="w-full sm:w-auto sm:min-w-[160px] bg-surface border border-border rounded-lg px-3 py-1.5 text-[13px] font-medium focus:border-accent outline-none transition-all appearance-none cursor-pointer text-foreground"
                  >
                    <option value="none">None</option>
                    <option value="nyaa">Torrents</option>
                    <option value="mkissa">Mkissa</option>
                    <option value="anineko">AniNeko</option>
                  </select>
                </SettingField>

                <SettingField label="Manga Provider" description="Source for manga chapters.">
                  <select
                    value={String(config.general?.manga_provider || "mangakatana")}
                    onChange={(e) => updateField("general", "manga_provider", e.target.value)}
                    className="w-full sm:w-auto sm:min-w-[160px] bg-surface border border-border rounded-lg px-3 py-1.5 text-[13px] font-medium focus:border-accent outline-none transition-all appearance-none cursor-pointer text-foreground"
                  >
                    <option value="mangakatana">MangaKatana</option>
                  </select>
                </SettingField>

                <SettingField label="Search & Tracking API" description="Metadata and list sync source.">
                  <select
                    value={String(config.general?.media_api || "anilist")}
                    onChange={(e) => updateField("general", "media_api", e.target.value)}
                    className="w-full sm:w-auto sm:min-w-[160px] bg-surface border border-border rounded-lg px-3 py-1.5 text-[13px] font-medium focus:border-accent outline-none transition-all appearance-none cursor-pointer text-foreground"
                  >
                    <option value="anilist">AniList</option>
                    <option value="jikan">Jikan (MyAnimeList - Fallback)</option>
                  </select>
                </SettingField>
              </CardSection>
            </div>
          )}

          {activeTab === "player" && (
            <div className="space-y-6 animate-fade-in">
              <CardSection title="Playback">

                <SettingField label="Sub/Dub" description="Preferred audio language for streaming.">
                  <select
                    value={String(config.stream?.translation_type || "sub")}
                    onChange={(e) => updateField("stream", "translation_type", e.target.value)}
                    className="w-full sm:w-auto sm:min-w-[160px] bg-surface border border-border rounded-lg px-3 py-1.5 text-[13px] font-medium focus:border-accent outline-none transition-all appearance-none cursor-pointer text-foreground"
                  >
                    <option value="sub">Subtitled (Japanese)</option>
                    <option value="dub">Dubbed (English)</option>
                  </select>
                </SettingField>

                <SettingField
                  label="Auto-Skip Intros"
                  description="Automatically skip openings and endings using AniSkip. Press S in-player to skip manually when disabled."
                >
                  <SettingToggle
                    on={Boolean(config.general?.autoskip)}
                    onChange={(v) => {
                      updateField("general", "autoskip", v);
                      useSettingsStore.getState().setAutoskip(v);
                    }}
                  />
                </SettingField>

                <SettingField
                  label="GPU Upscaling"
                  description="Anime4K — sharpens lines and adds depth with minimal battery impact. Ctrl+1 in-player toggles this too."
                >
                  <SettingToggle
                    on={(config.stream?.shader_profile || "on") !== "off"}
                    onChange={(v) => updateField("stream", "shader_profile", v ? "on" : "off")}
                  />
                </SettingField>

                <SettingField
                  label="Low Data Mode"
                  description="For slow connections. While something is playing, background traffic pauses so the stream gets all the bandwidth: no home-screen polling, no hover prefetching, and the next episode's torrent won't start downloading until the current one finishes. Manga pages load one at a time instead of six in parallel."
                >
                  <SettingToggle
                    on={Boolean(config.stream?.data_saver)}
                    onChange={(v) => {
                      updateField("stream", "data_saver", v);
                      useSettingsStore.getState().setDataSaver(v);
                    }}
                  />
                </SettingField>

              </CardSection>

              <CardSection title="Keyboard Shortcuts">
                <div className="space-y-4 text-xs leading-relaxed">
                  <p className="text-muted-foreground">When playing media in the external MPV window, you can use these shortcuts:</p>
                  <div>
                    <p className="meta-mono text-muted-foreground mb-2">Settings — Ctrl + number</p>
                    <div className="grid grid-cols-1 md:grid-cols-2 gap-3 border border-border p-4 rounded-lg bg-foreground/[0.02]">
                      <div className="flex justify-between py-1.5"><span className="text-foreground/70">Toggle Upscaling</span><kbd className="px-2 py-0.5 border border-border rounded text-[10px] text-foreground font-mono">Ctrl + 1</kbd></div>
                      <div className="flex justify-between py-1.5"><span className="text-foreground/70">Toggle Auto-skip Intro</span><kbd className="px-2 py-0.5 border border-border rounded text-[10px] text-foreground font-mono">Ctrl + 2</kbd></div>
                      <div className="flex justify-between py-1.5"><span className="text-foreground/70">Toggle Autoplay Next</span><kbd className="px-2 py-0.5 border border-border rounded text-[10px] text-foreground font-mono">Ctrl + 4</kbd></div>
                    </div>
                  </div>
                  <div>
                    <p className="meta-mono text-muted-foreground mb-2">Actions — Shift + letter</p>
                    <div className="grid grid-cols-1 md:grid-cols-2 gap-3 border border-border p-4 rounded-lg bg-foreground/[0.02]">
                      <div className="flex justify-between py-1.5"><span className="text-foreground/70">Reload Episode</span><kbd className="px-2 py-0.5 border border-border rounded text-[10px] text-foreground font-mono">Shift + R</kbd></div>
                      <div className="flex justify-between py-1.5"><span className="text-foreground/70">Skip Segment</span><kbd className="px-2 py-0.5 border border-border rounded text-[10px] text-foreground font-mono">Shift + S</kbd></div>
                      <div className="flex justify-between py-1.5"><span className="text-foreground/70">Toggle Sub/Dub</span><kbd className="px-2 py-0.5 border border-border rounded text-[10px] text-foreground font-mono">Shift + T</kbd></div>
                      <div className="flex justify-between py-1.5"><span className="text-foreground/70">Rotate Video</span><kbd className="px-2 py-0.5 border border-border rounded text-[10px] text-foreground font-mono">Shift + V</kbd></div>
                    </div>
                  </div>
                </div>
              </CardSection>
            </div>
          )}

          {activeTab === "account" && (
            <div className="space-y-6 animate-fade-in">
              <CardSection title="AniList">
                {config.api?.anilist_token ? (
                  <>
                    <SettingField label="Status" description="AniList account connection status.">
                      <div className="flex items-center gap-2">
                        {apiAuthenticated ? (
                          <>
                            <div className="w-2 h-2 rounded-full bg-green-500" />
                            <span className="text-sm text-green-400 font-medium">Connected</span>
                          </>
                        ) : (
                          <>
                            <div className="w-2 h-2 rounded-full bg-yellow-500" />
                            <span className="text-sm text-yellow-400 font-medium">Pending validation...</span>
                          </>
                        )}
                      </div>
                    </SettingField>
                    <SettingField label="API Token" description="Your authorization token. Keep this private.">
                      <input
                        type="password"
                        value={String(config.api?.anilist_token || "")}
                        onChange={(e) => {
                          const val = e.target.value.trim();
                          const hashMatch = val.match(/#.*access_token=([^&]+)/);
                          const token = hashMatch ? decodeURIComponent(hashMatch[1]) : val;
                          updateField("api", "anilist_token", token);
                          if (token.length > 20) {
                            mediaApi.updateConfig({ api: { anilist_token: token } }).then(() => {
                              useAppStore.getState().setConnectionState(true, true, false);
                              dispatchRefresh();
                              window.dispatchEvent(new Event("anicat_health_recheck"));
                            });
                          }
                        }}
                        placeholder="Paste redirect URL or token..."
                        className="w-full bg-surface border border-border rounded-lg px-3 py-1.5 text-[13px] font-medium focus:border-accent outline-none transition-all placeholder:text-muted-foreground"
                      />
                    </SettingField>
                    <div className="pt-2">
                      <button
                        onClick={async () => {
                          if (logoutState === "confirming") {
                            setLogoutState("loggingOut");
                            mediaApi.updateConfig({ anilist: { token: "" } })
                              .then(() => {
                                localStorage.removeItem("anicat-query-cache");
                                window.location.reload();
                              })
                              .catch(() => {
                                setLogoutState("idle");
                              });
                          } else {
                            setLogoutState("confirming");
                          }
                        }}
                        disabled={logoutState === "loggingOut"}
                        className={`mt-2 text-xs font-bold flex items-center space-x-1 w-full justify-center ${
                          logoutState === "loggingOut"
                            ? "text-red-400/40"
                            : logoutState === "confirming"
                              ? "text-red-400 hover:text-red-300"
                              : "text-red-400/60 hover:text-red-400"
                        }`}
                      >
                        <span>
                          {logoutState === "loggingOut" ? "Logging out..." : logoutState === "confirming" ? "Are you sure? Click again" : "Logout"}
                        </span>
                      </button>
                    </div>
                  </>
                ) : (
                  <>
                    <SettingField label="Login" description="Authorize Anicat to access your AniList account.">
                      <button
                        onClick={() => {
                          setAuthPending(true);
                          invoke("start_anilist_auth").then(() => {
                            setAuthPending(false);
                          }).catch(() => {
                            setAuthPending(false);
                          });
                        }}
                        className="w-full flex items-center justify-center space-x-2 px-4 py-3 rounded-md bg-accent/10 border border-accent/20 hover:bg-accent/20 text-accent font-semibold text-sm transition-all"
                      >
                        {authPending ? (
                          <>
                            <Loader2 size={16} className="animate-spin" />
                            <span>Waiting for authorization...</span>
                          </>
                        ) : (
                          <>
                            <Globe size={16} />
                            <span>Connect AniList</span>
                          </>
                        )}
                      </button>
                    </SettingField>
                    <SettingField label="API Token" description="After authorizing, paste the full URL you were redirected to (or just the token).">
                      <input
                        type="password"
                        value={String(config.api?.anilist_token || "")}
                        onChange={(e) => {
                          const val = e.target.value.trim();
                          const hashMatch = val.match(/#.*access_token=([^&]+)/);
                          const token = hashMatch ? decodeURIComponent(hashMatch[1]) : val;
                          updateField("api", "anilist_token", token);
                          if (token.length > 20) {
                            mediaApi.updateConfig({ api: { anilist_token: token } }).then(() => {
                              useAppStore.getState().setConnectionState(true, true, false);
                              dispatchRefresh();
                              window.dispatchEvent(new Event("anicat_health_recheck"));
                            });
                          }
                        }}
                        placeholder="Paste redirect URL or token..."
                        className="w-full bg-surface border border-border rounded-lg px-3 py-1.5 text-[13px] font-medium focus:border-accent outline-none transition-all placeholder:text-muted-foreground"
                      />
                    </SettingField>
                  </>
                )}
                <div className="mt-4 p-3 border border-border rounded-lg space-y-1.5 text-xs font-mono bg-foreground/[0.02]">
                  <div className="flex justify-between"><span className="text-muted-foreground">Token saved</span><span className={tokenPresent ? "text-green-400" : "text-muted-foreground/60"}>{tokenPresent ? "yes" : "no"}</span></div>
                  <div className="flex justify-between"><span className="text-muted-foreground">Backend connected</span><span className={apiConnected ? "text-green-400" : "text-red-400"}>{apiConnected ? "yes" : "no"}</span></div>
                  <div className="flex justify-between"><span className="text-muted-foreground">AniList validated</span><span className={apiAuthenticated ? "text-green-400" : "text-red-400"}>{apiAuthenticated ? "yes" : "no"}</span></div>
                  {authError && (
                    authError.startsWith("anilist_down:") ? (
                      <div className="mt-2 p-2 rounded bg-yellow-500/10 border border-yellow-500/20 text-yellow-300 text-[10px] leading-snug">
                        AniList is temporarily down: {authError.slice("anilist_down:".length)}
                      </div>
                    ) : (
                      <div className="flex justify-between"><span className="text-muted-foreground">Error</span><span className="text-red-400 ml-2 text-[10px] leading-snug break-all">{authError}</span></div>
                    )
                  )}
                  {health?.viewer_name && (
                    <div className="flex justify-between"><span className="text-muted-foreground">Signed in as</span><span className="text-accent">{health.viewer_name}</span></div>
                  )}
                </div>
              </CardSection>
            </div>
          )}

          {activeTab === "maintenance" && (
            <div className="space-y-6 animate-fade-in">
              {/* Update */}
              <CardSection title="Updates" description="Keep the app up to date.">
                <div className="flex items-center justify-between pb-2">
                  <div className="text-sm text-muted-foreground">
                    Current version: <span className="font-mono text-foreground">{health?.current_version || "unknown"}</span>
                  </div>
                </div>

                <div className="space-y-4">
                  <button
                    onClick={handleUpdate}
                    disabled={checkingUpdate}
                    className={`w-full flex items-center justify-center space-x-2 py-3 rounded-md font-bold transition-all shadow-lg active:scale-[0.98] disabled:opacity-50 ${hasUpdate
                      ? "bg-green-600 hover:bg-green-500 text-white shadow-green-500/20"
                      : "bg-accent text-white hover:bg-accent-light"
                      }`}
                  >
                    {checkingUpdate ? (
                      <Loader2 size={16} className="animate-spin" />
                    ) : hasUpdate ? (
                      <Download size={16} />
                    ) : (
                      <RotateCcw size={16} />
                    )}
                    <span>
                      {checkingUpdate
                        ? (hasUpdate ? "Updating..." : "Checking...")
                        : hasUpdate
                          ? "Install Update"
                          : "Check for Updates"}
                    </span>
                  </button>

                  {updateMessage.text && (
                    <div className={`p-4 rounded-md text-xs font-semibold flex items-start space-x-3 animate-fade-in ${updateMessage.type === "success"
                      ? "bg-green-500/10 text-green-400 border border-green-500/20"
                      : "bg-red-500/10 text-red-400 border border-red-500/20"
                      }`}>
                      {updateMessage.type === "success" ? (
                        <CheckCircle2 size={15} className="mt-0.5 shrink-0" />
                      ) : (
                        <AlertCircle size={15} className="mt-0.5 shrink-0" />
                      )}
                      <span>{updateMessage.text}</span>
                    </div>
                  )}

                  {releaseNotes && (
                    <div className="p-4 rounded-md border border-border text-xs text-muted-foreground max-h-48 overflow-y-auto animate-fade-in bg-foreground/[0.02]">
                      <div className="meta-mono text-muted-foreground mb-2">Release Notes</div>
                      <div className="whitespace-pre-wrap leading-relaxed">{releaseNotes}</div>
                      {releaseUrl && (
                        <a
                          href={releaseUrl}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="inline-block mt-3 text-accent hover:text-accent-light font-medium transition-colors"
                        >
                          View on GitHub →
                        </a>
                      )}
                    </div>
                  )}
                </div>
              </CardSection>

              {/* Logs & Debugging */}
              <CardSection title="Logs & Debugging">
                <button
                  onClick={async () => {
                    try {
                      const logs = await mediaApi.getLogs(50);
                      const report = [
                        `Anicat Version: ${health?.current_version || "unknown"}`,
                        `Platform: ${window.navigator.platform}`,
                        `User Agent: ${window.navigator.userAgent}`,
                        `API Connected: ${health?.connected}`,
                        `API Authenticated: ${health?.authenticated}`,
                        `Is Offline: ${health?.offline}`,
                        `Timestamp: ${new Date().toISOString()}`,
                        `\n--- LATEST LOGS ---\n`,
                        logs.logs
                      ].join('\n');
                      await navigator.clipboard.writeText(report);
                      setErrorMessage("Debug report copied to clipboard!");
                      setTimeout(() => setErrorMessage(null), 4000);
                    } catch {
                      setErrorMessage("Failed to generate report.");
                      setTimeout(() => setErrorMessage(null), 6000);
                    }
                  }}
                  className="w-full py-2.5 border-border text-foreground/70 hover:text-foreground rounded-md text-xs font-bold transition-all border border-border flex items-center justify-center space-x-2 hover:bg-foreground/[0.03]"
                >
                  <Save size={14} />
                  <span>Copy Debug Report</span>
                </button>
                <div className="w-full h-40 bg-foreground/[0.03] rounded-md p-3 text-[10px] font-mono text-muted-foreground overflow-y-auto border border-border whitespace-pre-wrap text-left font-sans leading-normal">
                  {logsText}
                </div>
              </CardSection>

              {/* Provider Test */}
              <CardSection title="Provider Test" description="Check whether a provider can fetch streams for an episode.">
                <div className="space-y-3">
                  <div className="flex items-center gap-2">
                    <input
                      ref={debugNameRef}
                      type="text"
                      placeholder="Anime name"
                      onKeyDown={(e) => { if (e.key === "Enter") runProviderTest(); }}
                      className="flex-1 bg-surface border border-border rounded-md p-3 text-sm font-medium focus:border-accent outline-none transition-all text-foreground placeholder:text-muted-foreground"
                    />
                    <input ref={debugEpisodeRef} type="number" min="1" placeholder="Ep" defaultValue="1" aria-label="Episode number" className="w-[64px] bg-surface border border-border rounded-md p-3 text-sm font-medium focus:border-accent outline-none transition-all text-foreground" />
                    <select ref={debugProviderRef} defaultValue="mkissa" aria-label="Provider" className="bg-surface border border-border rounded-md p-3 text-sm font-medium focus:border-accent outline-none transition-all appearance-none cursor-pointer text-foreground">
                      <option value="mkissa" className="bg-surface">Mkissa</option>
                      <option value="anineko" className="bg-surface">AniNeko</option>
                    </select>
                    <button
                      onClick={runProviderTest}
                      disabled={debugBusy}
                      className="px-4 py-3 rounded-md bg-accent hover:bg-accent-light text-white font-bold text-sm transition-all active:scale-[0.98] disabled:opacity-50 flex items-center gap-2"
                    >
                      {debugBusy ? <Loader2 size={16} className="animate-spin" /> : null}
                      Test
                    </button>
                  </div>
                  {debugResult && (
                    <div className={`flex items-start gap-2 rounded-md p-3 text-sm border ${debugResult.ok ? "bg-green-500/10 border-green-500/20 text-green-300" : "bg-red-500/10 border-red-500/20 text-red-300"}`}>
                      {debugResult.ok ? <CheckCircle2 size={16} className="shrink-0 mt-0.5" /> : <XCircle size={16} className="shrink-0 mt-0.5" />}
                      <span className="flex-1 leading-relaxed">{debugResult.summary}</span>
                      {debugResult.raw && (
                        <button
                          onClick={() => navigator.clipboard.writeText(debugResult.raw)}
                          className="shrink-0 p-1.5 rounded-lg bg-foreground/[0.06] hover:bg-foreground/[0.10] text-muted-foreground hover:text-foreground transition-all"
                          title="Copy raw response for a bug report"
                        >
                          <Copy size={13} />
                        </button>
                      )}
                    </div>
                  )}
                </div>
              </CardSection>

              {/* System Maintenance */}
              <CardSection title="System Maintenance" description="Irreversible system actions.">
                <button
                  onClick={() => {
                    if (registryState === "confirming") {
                      setRegistryState("wiping");
                      mediaApi.wipeRegistry().then(() => {
                        setRegistryState("done");
                        setTimeout(() => window.location.reload(), 1500);
                      }).catch((err) => {
                        console.error("Wipe failed:", err);
                        setRegistryState("idle");
                      });
                    } else if (registryState === "idle") {
                      setRegistryState("confirming");
                    }
                  }}
                  disabled={registryState === "wiping" || registryState === "done"}
                  className={`w-full py-3 rounded-md text-sm font-bold transition-all ${
                    registryState === "wiping"
                      ? "bg-red-500/10 text-red-400/40 border border-red-500/10 cursor-not-allowed"
                      : registryState === "done"
                        ? "bg-green-500/20 text-green-400 border border-green-500/30"
                        : registryState === "confirming"
                          ? "bg-red-500/20 text-red-400 border border-red-500/30"
                          : "border border-red-500/20 text-red-400/60 hover:bg-red-500/10"
                  }`}
                >
                  {registryState === "wiping" ? "Wiping Registry..." : registryState === "done" ? "Registry Wiped! Restarting..." : registryState === "confirming" ? "Are you sure? This will wipe your history!" : "Clear Local Registry"}
                </button>
                <button
                  onClick={() => {
                    if (resetOnboardingState === "confirming") {
                      localStorage.removeItem("anicat_onboarding_seen");
                      window.location.reload();
                    } else {
                      setResetOnboardingState("confirming");
                    }
                  }}
                  className={`w-full py-3 px-4 rounded-md text-[10px] font-bold transition-all flex items-center justify-center space-x-2 ${
                    resetOnboardingState === "confirming"
                      ? "bg-red-500/20 text-red-400 border border-red-500/30"
                      : "bg-foreground/[0.03] hover:bg-foreground/[0.06] text-muted-foreground border border-border"
                  }`}
                >
                  <RotateCcw size={12} />
                  <span>{resetOnboardingState === "confirming" ? "Are you sure? Click again to Reset" : "Reset Onboarding Setup"}</span>
                </button>
              </CardSection>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

/* System Settings grammar: the group label sits outside the card, the card
   itself is a flat inset with hairline dividers between rows, and controls
   are compact and right-aligned. */
function CardSection({ title, description, children }: { title: string; description?: string; children: React.ReactNode }) {
  return (
    <section className="glass-panel overflow-hidden">
      <div className="px-5 py-3.5 border-b border-border bg-foreground/[0.02]">
        <h3 className="text-[13px] font-semibold text-foreground">{title}</h3>
        {description && <p className="text-xs text-muted-foreground mt-0.5 max-w-xl leading-relaxed">{description}</p>}
      </div>
      <div className="p-4 space-y-3">{children}</div>
    </section>
  );
}

function SettingField({ label, description, children, stack }: { label: string; description?: string; children: React.ReactNode; stack?: boolean }) {
  return (
    <div className={`py-2.5 ${stack ? "space-y-3" : "flex flex-col sm:flex-row sm:items-center gap-3"}`}>
      <div className="flex-1 min-w-0">
        <label className="text-[13px] font-medium text-foreground">{label}</label>
        {description && <p className="text-xs text-muted-foreground mt-0.5 leading-relaxed">{description}</p>}
      </div>
      <div className={stack ? "" : "w-full sm:w-56 shrink-0 sm:text-right"}>{children}</div>
    </div>
  );
}

function SettingToggle({ on, onChange, disabled }: { on: boolean; onChange: (v: boolean) => void; disabled?: boolean }) {
  return (
    <button
      role="switch"
      aria-checked={on}
      disabled={disabled}
      onClick={() => onChange(!on)}
      className={`relative inline-block h-[22px] w-[38px] shrink-0 rounded-full transition-colors duration-200 align-middle ${
        on ? "bg-accent" : "bg-foreground/20"
      } disabled:opacity-40`}
    >
      <span
        className={`absolute top-[2px] h-[18px] w-[18px] rounded-full bg-foreground shadow-sm transition-all duration-200 ${
          on ? "left-[18px]" : "left-[2px]"
        }`}
      />
    </button>
  );
}

