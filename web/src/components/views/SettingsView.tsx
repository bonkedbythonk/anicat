
import { useState, useEffect, useRef, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Loader2, CheckCircle2, Save, Cpu, PlayCircle, HardDrive, Globe, RotateCcw, XCircle, AlertCircle, Download, Copy } from "lucide-react";
import { mediaApi, type HealthStatus, API_BASE_ORIGIN, dispatchRefresh } from "@/lib/api";
import { useAppStore, useSettingsStore } from "@/stores/app";
import type { UiStyle } from "@/hooks/useTheme";
import { ErrorBanner } from "@/components/ErrorBanner";

interface SettingsViewProps {
  health: HealthStatus | null;
  onUpdateStarted?: (message?: string) => void;
}

export function SettingsView({ health, onUpdateStarted }: SettingsViewProps) {
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
      setActiveTab(tab as any);
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
  const [homeRows, setHomeRows] = useState<any[] | null>(() => {
    try {
      const saved = typeof window !== "undefined" ? localStorage.getItem("anicat_home_rows") : null;
      return saved ? JSON.parse(saved) : null;
    } catch { return null; }
  });
  const toggleHomeRow = (id: string) => {
    const rowDefs = ["airingToday", "continue", "newForYou", "smartPlaylist", "trending", "newlyReleasing", "seasonal"];
    const current = homeRows || rowDefs.map(id => ({ id, visible: true }));
    const next = current.map((r: any) => r.id === id ? { ...r, visible: !r.visible } : r);
    setHomeRows(next);
    localStorage.setItem("anicat_home_rows", JSON.stringify(next));
    window.dispatchEvent(new Event("anicat_home_rows_changed"));
  };
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  const [theme, setTheme] = useState<"system" | "dark" | "light">("system");
  const [uiStyle, setUiStyle] = useState<UiStyle>("neon-abyss");
  const [logoutState, setLogoutState] = useState<"idle" | "confirming" | "loggingOut">("idle");
  const [registryState, setRegistryState] = useState<"idle" | "confirming" | "wiping" | "done">("idle");
  const [resetOnboardingState, setResetOnboardingState] = useState<"idle" | "confirming">("idle");
  const [debugOutput, setDebugOutput] = useState("Press Test to run.");
  const [debugName, setDebugName] = useState("");
  const debugSearchRef = useRef<HTMLInputElement>(null);
  const debugMediaIdRef = useRef<HTMLInputElement>(null);
  const debugEpisodeRef = useRef<HTMLInputElement>(null);
  const debugProviderRef = useRef<HTMLSelectElement>(null);

  const hasUpdate = Boolean(health?.update_available || stagedHasUpdate);

  useEffect(() => {
    if (typeof window !== "undefined") {
      const savedTheme = localStorage.getItem("anicat_theme") as "system" | "dark" | "light" | null;
      const savedStyle = localStorage.getItem("anicat_ui_style") as UiStyle | null;

      setTimeout(() => {
        if (savedTheme) {
          setTheme(savedTheme);
        }
        if (savedStyle) {
          setUiStyle(savedStyle);
        }
      }, 0);
    }
  }, []);

  const handleThemeChange = (newTheme: "system" | "dark" | "light") => {
    // Inject the theme-transition class temporarily to animate variables
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

    // Clean up transition class after animation completes
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

  const handleOpenLogs = async () => {
    try {
      const { invoke } = await import("@tauri-apps/api/core");
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
          if (onUpdateStarted) {
            onUpdateStarted(res.message);
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
      const updated = {
        ...prev,
        [section]: { ...prev[section], [field]: value }
      };
      autoSave({
        [section]: {
          [field]: value
        }
      });
      return updated;
    });
  };

  const handleBackup = async () => {
    setBackingUp(true);
    setBackupUrl(null);
    try {
      await mediaApi.triggerBackup();
      setBackupUrl(`${API_BASE_ORIGIN}/api/registry/backup/download`);
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
        <div className="flex items-center space-x-3 px-5 py-3.5 rounded-2xl bg-green-500/10 border border-green-500/20 text-green-400 font-bold text-sm animate-fade-in shadow-lg">
          <CheckCircle2 size={18} />
          <span>{successMessage}</span>
          <button onClick={() => setSuccessMessage(null)} className="ml-auto p-1 hover:bg-green-500/10 rounded-lg transition-colors">
            <XCircle size={16} />
          </button>
        </div>
      )}
      {errorMessage && <ErrorBanner message={errorMessage} />}
      <div className="flex items-end justify-between">
        <h1 className="text-4xl lg:text-5xl font-extrabold tracking-tight text-white">Settings</h1>
        <div className="flex items-center space-x-2">
          {saving && (
            <div className="flex items-center space-x-1.5 text-xs text-gray-500 font-medium">
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
          <div className="lg:sticky lg:top-2 flex lg:flex-col gap-1 bg-white/[0.02] lg:bg-transparent p-1 lg:p-0 rounded-xl border lg:border-0 border-white/[0.06] overflow-x-auto scrollbar-hide">
            {tabs.map((tab) => (
              <button
                key={tab.id}
                onClick={() => setActiveTab(tab.id)}
                className={`flex items-center gap-2.5 px-4 py-2.5 rounded-xl font-semibold text-sm whitespace-nowrap transition-all justify-center lg:w-full lg:justify-start ${
                  activeTab === tab.id
                    ? "bg-accent text-white shadow-lg shadow-accent/20"
                    : "text-gray-500 hover:text-white hover:bg-white/[0.04]"
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
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
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
                    {/* Neon Abyss */}
                    <button
                      onClick={() => handleStyleChange("neon-abyss")}
                      className={`relative rounded-2xl overflow-hidden border-2 transition-all text-left ${
                        uiStyle === "neon-abyss"
                          ? "border-[#0A84FF] shadow-lg shadow-[#0A84FF]/20"
                          : "border-white/[0.06] hover:border-white/[0.15]"
                      }`}
                    >
                      {/* Preview swatch */}
                      <div className="h-20 w-full" style={{ background: "linear-gradient(135deg, #050505 0%, #0d0d1a 60%, #1a1025 100%)" }}>
                        <div className="flex gap-1 p-2 h-full items-end">
                          <div className="flex-1 h-8 rounded-xl" style={{ background: "rgba(28,28,30,0.6)", border: "1px solid rgba(255,255,255,0.08)" }} />
                          <div className="flex-1 h-8 rounded-xl" style={{ background: "rgba(10,132,255,0.3)", border: "1px solid rgba(10,132,255,0.4)" }} />
                        </div>
                      </div>
                      <div className="px-3 py-2 bg-white/[0.02] h-14 flex flex-col justify-center">
                        <div className="text-xs font-bold text-white">Neon Abyss</div>
                        <div className="text-[10px] text-gray-500 mt-0.5">Deep black / Apple glass</div>
                      </div>
                      {uiStyle === "neon-abyss" && (
                        <div className="absolute top-2 right-2 w-4 h-4 rounded-full bg-[#0A84FF] flex items-center justify-center">
                          <svg width="8" height="8" viewBox="0 0 8 8" fill="none"><path d="M1 4l2 2 4-4" stroke="white" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/></svg>
                        </div>
                      )}
                    </button>

                    {/* Sakura Zen */}
                    <button
                      onClick={() => handleStyleChange("sakura-zen")}
                      className={`relative rounded-2xl overflow-hidden border-2 transition-all text-left ${
                        uiStyle === "sakura-zen"
                          ? "border-[#e8a0b4] shadow-lg shadow-[#e8a0b4]/20"
                          : "border-white/[0.06] hover:border-white/[0.15]"
                      }`}
                    >
                      {/* Preview swatch */}
                      <div className="h-20 w-full" style={{ background: "linear-gradient(135deg, #0f0b10 0%, #1a1018 60%, #1f1222 100%)" }}>
                        <div className="flex gap-1 p-2 h-full items-end">
                          <div className="flex-1 h-8 rounded-xl" style={{ background: "rgba(244,180,196,0.08)", border: "1px solid rgba(232,160,180,0.2)" }} />
                          <div className="flex-1 h-8 rounded-xl" style={{ background: "rgba(232,160,180,0.25)", border: "1px solid rgba(232,160,180,0.4)" }} />
                        </div>
                      </div>
                      <div className="px-3 py-2 h-14 flex flex-col justify-center" style={{ background: "rgba(244,180,196,0.04)" }}>
                        <div className="text-xs font-bold" style={{ color: "#f2bfce" }}>Sakura Zen</div>
                        <div className="text-[10px] mt-0.5" style={{ color: "#9ab89a" }}>Soft pastel / Japanese editorial</div>
                      </div>
                      {uiStyle === "sakura-zen" && (
                        <div className="absolute top-2 right-2 w-4 h-4 rounded-full flex items-center justify-center" style={{ background: "#e8a0b4" }}>
                          <svg width="8" height="8" viewBox="0 0 8 8" fill="none"><path d="M1 4l2 2 4-4" stroke="white" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/></svg>
                        </div>
                      )}
                    </button>

                    {/* Retro Manga */}
                    <button
                      onClick={() => handleStyleChange("retro-manga")}
                      className={`relative rounded-2xl overflow-hidden border-2 transition-all text-left ${
                        uiStyle === "retro-manga"
                          ? "border-[#e8272c] shadow-lg shadow-[#e8272c]/20"
                          : "border-white/[0.06] hover:border-white/[0.15]"
                      }`}
                    >
                      {/* Preview swatch */}
                      <div className="h-20 w-full" style={{ background: "linear-gradient(135deg, #1a1510 0%, #231e18 100%)" }}>
                        <div className="flex gap-1 p-2 h-full items-end">
                          <div className="flex-1 h-8 rounded" style={{ background: "#ede8e0", border: "3px solid #1a1a1a" }} />
                          <div className="flex-1 h-8 rounded" style={{ background: "#e8272c", border: "2px solid #1a1a1a" }} />
                        </div>
                      </div>
                      <div className="px-3 py-2 h-14 flex flex-col justify-center" style={{ background: "rgba(232, 39, 44, 0.04)" }}>
                        <div className="text-xs font-bold" style={{ color: "#e8272c" }}>Retro Manga</div>
                        <div className="text-[10px] mt-0.5 text-gray-500">Halftone dot / Manga panel style</div>
                      </div>
                      {uiStyle === "retro-manga" && (
                        <div className="absolute top-2 right-2 w-4 h-4 rounded-full flex items-center justify-center" style={{ background: "#e8272c" }}>
                          <svg width="8" height="8" viewBox="0 0 8 8" fill="none"><path d="M1 4l2 2 4-4" stroke="white" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/></svg>
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
                    onChange={(e) => updateField("general", "time_format", e.target.value)}
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
                  >
                    <option value="12h">12-hour (AM/PM)</option>
                    <option value="24h">24-hour</option>
                  </select>
                </SettingField>
              </CardSection>

              <CardSection title="Homepage Layout" description="Show or hide sections on the homepage.">
                {(() => {
                  const rowDefs = [
                    { id: "airingToday", label: "Airing Today" },
                    { id: "continue", label: "Continue Watching" },
                    { id: "newForYou", label: "New for You" },
                    { id: "smartPlaylist", label: "Smart Playlist" },
                    { id: "trending", label: "Trending Now" },
                    { id: "newlyReleasing", label: "Newly Releasing" },
                    { id: "seasonal", label: "Seasonal Highlights" },
                  ];
                  return rowDefs.map(r => {
                    const row = (homeRows || rowDefs.map(x => ({ id: x.id, visible: true }))).find((x: any) => x.id === r.id);
                    const visible = row ? row.visible : true;
                    return (
                      <label key={r.id} className="flex items-center justify-between px-3 py-3 rounded-xl hover:bg-white/[0.015] transition-colors cursor-pointer group">
                        <div className="text-sm font-semibold text-white group-hover:text-accent transition-colors">{r.label}</div>
                        <input
                          type="checkbox"
                          checked={visible}
                          onChange={() => toggleHomeRow(r.id)}
                          className="accent-accent rounded cursor-pointer w-4 h-4"
                        />
                      </label>
                    );
                  });
                })()}
              </CardSection>

              <CardSection title="Advanced" description="Rarely need to change these after initial setup.">
                <SettingField label="Discord Rich Presence" description="Show current anime in your Discord status.">
                  <select
                    value={config.general?.discord ? "true" : "false"}
                    onChange={(e) => updateField("general", "discord", e.target.value === "true")}
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
                  >
                    <option value="false">Disabled</option>
                    <option value="true">Enabled</option>
                  </select>
                </SettingField>

                <SettingField label="Download Location" description="Where downloaded episodes are saved.">
                  <div className="relative">
                    <HardDrive size={16} className="absolute left-4 top-1/2 -translate-y-1/2 text-gray-600" />
                    <input
                      type="text"
                      value={String(config.general?.downloads_path || "")}
                      onChange={(e) => updateField("general", "downloads_path", e.target.value)}
                      className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl py-3.5 pl-11 pr-4 text-sm font-medium focus:border-accent/40 outline-none transition-all"
                    />
                  </div>
                </SettingField>

                <SettingField label="Anime Provider" description="Primary streaming source.">
                  <select
                    value={String(config.general?.provider || "allanime")}
                    onChange={(e) => updateField("general", "provider", e.target.value)}
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
                  >
                    <option value="allanime">AllAnime</option>
                    <option value="anineko">AniNeko</option>
                  </select>
                </SettingField>

                <SettingField label="Fallback Provider" description="Used when the primary provider fails.">
                  <select
                    value={String(config.general?.fallback_provider || "anineko")}
                    onChange={(e) => updateField("general", "fallback_provider", e.target.value)}
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
                  >
                    <option value="none">None</option>
                    <option value="allanime">AllAnime</option>
                    <option value="anineko">AniNeko</option>
                  </select>
                </SettingField>

                <SettingField label="Manga Provider" description="Source for manga chapters.">
                  <select
                    value={String(config.general?.manga_provider || "mangakatana")}
                    onChange={(e) => updateField("general", "manga_provider", e.target.value)}
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
                  >
                    <option value="mangakatana">MangaKatana</option>
                  </select>
                </SettingField>

                <SettingField label="Search & Tracking API" description="Metadata and list sync source.">
                  <select
                    value={String(config.general?.media_api || "anilist")}
                    onChange={(e) => updateField("general", "media_api", e.target.value)}
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
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
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
                  >
                    <option value="sub">Subtitled (Japanese)</option>
                    <option value="dub">Dubbed (English)</option>
                  </select>
                </SettingField>

                <SettingField
                  label="Auto-Skip Intros"
                  description="Automatically skip openings and endings using AniSkip. Press S in-player to skip manually when disabled."
                >
                  <select
                    value={config.general?.autoskip ? "true" : "false"}
                    onChange={(e) => {
                      updateField("general", "autoskip", e.target.value === "true");
                      useSettingsStore.getState().setAutoskip(e.target.value === "true");
                    }}
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
                  >
                    <option value="false">Disabled (Manual S)</option>
                    <option value="true">Enabled (Automatic)</option>
                  </select>
                </SettingField>

                <SettingField
                  label="GPU Upscaling"
                  description="Anime4K — sharpens lines and adds depth with minimal battery impact. Ctrl+1 in-player toggles temporarily without changing this setting."
                >
                  <button
                    onClick={() => updateField("stream", "shader_profile", (config.stream?.shader_profile || "on") === "off" ? "on" : "off")}
                    className={`flex items-center space-x-2 px-4 py-3.5 rounded-xl text-sm font-bold transition-all w-full ${
                      (config.stream?.shader_profile || "on") !== "off"
                        ? "bg-accent/15 text-accent border border-accent/30 shadow-sm shadow-accent/5"
                        : "bg-white/[0.03] text-muted-foreground border border-white/[0.08] hover:bg-white/[0.06]"
                    }`}
                  >
                    <Cpu size={16} />
                    <span>{(config.stream?.shader_profile || "on") !== "off" ? "On" : "Off"}</span>
                  </button>
                </SettingField>
              </CardSection>

              <CardSection title="Keyboard Shortcuts">
                <div className="space-y-3 text-xs leading-relaxed">
                  <p className="text-gray-400">When playing media in the external MPV window, you can use these shortcuts:</p>
                  <div className="grid grid-cols-1 md:grid-cols-2 gap-3 bg-white/[0.02] border border-white/[0.05] p-4 rounded-2xl">
                    <div className="flex justify-between py-1.5 border-b border-white/[0.02]"><span className="text-gray-400">Skip Segment</span><kbd className="px-2 py-0.5 bg-white/[0.08] border border-white/[0.1] rounded text-[10px] text-white font-mono font-bold">Shift + S</kbd></div>
                    <div className="flex justify-between py-1.5 border-b border-white/[0.02]"><span className="text-gray-400">Toggle Sub/Dub</span><kbd className="px-2 py-0.5 bg-white/[0.08] border border-white/[0.1] rounded text-[10px] text-white font-mono font-bold">Shift + T</kbd></div>
                    <div className="flex justify-between py-1.5 border-b border-white/[0.02]"><span className="text-gray-400">Toggle Upscaling (temp)</span><kbd className="px-2 py-0.5 bg-white/[0.08] border border-white/[0.1] rounded text-[10px] text-white font-mono font-bold">Ctrl + 1</kbd></div>
                    <div className="flex justify-between py-1.5 border-b border-white/[0.02]"><span className="text-gray-400">Toggle Autoplay Next</span><kbd className="px-2 py-0.5 bg-white/[0.08] border border-white/[0.1] rounded text-[10px] text-white font-mono font-bold">Shift + A</kbd></div>
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
                        className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all placeholder:text-gray-700"
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
                        className="w-full flex items-center justify-center space-x-2 px-4 py-3 rounded-xl bg-accent/10 border border-accent/20 hover:bg-accent/20 text-accent font-semibold text-sm transition-all"
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
                        className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all placeholder:text-gray-700"
                      />
                    </SettingField>
                  </>
                )}
                <div className="mt-4 p-3 bg-white/[0.02] border border-white/[0.05] rounded-lg space-y-1 text-xs font-mono">
                  <div className="flex justify-between"><span className="text-gray-500">Token saved</span><span className={tokenPresent ? "text-green-400" : "text-gray-600"}>{tokenPresent ? "yes" : "no"}</span></div>
                  <div className="flex justify-between"><span className="text-gray-500">Backend connected</span><span className={apiConnected ? "text-green-400" : "text-red-400"}>{apiConnected ? "yes" : "no"}</span></div>
                  <div className="flex justify-between"><span className="text-gray-500">AniList validated</span><span className={apiAuthenticated ? "text-green-400" : "text-red-400"}>{apiAuthenticated ? "yes" : "no"}</span></div>
                  {authError && (
                    <div className="flex justify-between"><span className="text-gray-500">Error</span><span className="text-red-400 truncate ml-2 text-[10px]">{authError}</span></div>
                  )}
                  {health?.viewer_name && (
                    <div className="flex justify-between"><span className="text-gray-500">Signed in as</span><span className="text-accent">{health.viewer_name}</span></div>
                  )}
                </div>
              </CardSection>
            </div>
          )}

          {activeTab === "maintenance" && (
            <div className="space-y-6 animate-fade-in">
              {/* Update */}
              <CardSection title="Updates" description="Keep the app up to date.">
                <div className="flex items-center justify-between pb-4 border-b border-white/[0.04]">
                  <div className="text-sm text-gray-400">
                    Current version: <span className="font-mono text-white">{health?.current_version || "unknown"}</span>
                  </div>
                </div>

                <div className="space-y-4">
                  <button
                    onClick={handleUpdate}
                    disabled={checkingUpdate}
                    className={`w-full flex items-center justify-center space-x-2 py-3 rounded-xl font-bold transition-all shadow-lg active:scale-[0.98] disabled:opacity-50 ${hasUpdate
                      ? "bg-green-600 hover:bg-green-500 text-white shadow-green-500/20"
                      : "bg-accent text-white hover:bg-accent-light shadow-accent/20"
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
                    <div className={`p-4 rounded-xl text-xs font-semibold flex items-start space-x-3 animate-fade-in ${updateMessage.type === "success"
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
                    <div className="p-4 rounded-xl bg-white/[0.02] border border-white/[0.06] text-xs text-gray-400 max-h-48 overflow-y-auto animate-fade-in">
                      <div className="font-bold text-gray-300 mb-2 text-[10px] uppercase tracking-wider">Release Notes</div>
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
                  className="w-full py-2.5 bg-white/[0.04] hover:bg-white/[0.07] text-white/70 rounded-xl text-xs font-bold transition-all border border-white/5 flex items-center justify-center space-x-2"
                >
                  <Save size={14} />
                  <span>Copy Debug Report</span>
                </button>
                <div className="w-full h-40 bg-black/40 rounded-xl p-3 text-[10px] font-mono text-gray-400 overflow-y-auto border border-white/5 whitespace-pre-wrap text-left font-sans leading-normal">
                  {logsText}
                </div>
              </CardSection>

              {/* Provider Debug */}
              <CardSection title="Provider Debug" description="Test stream provider responses for a given anime and episode.">
                <div className="space-y-3">
                  <input ref={debugSearchRef} type="text" placeholder="Search anime (e.g. Code Geass)..." className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3 text-sm font-medium focus:border-accent/40 outline-none transition-all text-white placeholder-gray-500"
                    onKeyDown={async (e: any) => {
                      if (e.key !== 'Enter') return;
                      const q = debugSearchRef.current?.value;
                      if (!q) return;
                      try {
                        const res = await mediaApi.search(q, "ANIME", 1);
                        const first = res?.media?.[0];
                        if (first?.id && debugMediaIdRef.current) {
                          debugMediaIdRef.current.value = String(first.id);
                          setDebugName(first.title?.english || first.title?.romaji || '');
                        }
                      } catch {}
                    }}
                  />
                  {debugName && (
                    <div className="text-xs text-gray-500 px-1 font-medium">{debugName}</div>
                  )}
                  <div className="flex items-center space-x-2">
                    <input ref={debugMediaIdRef} type="number" placeholder="Anime ID" className="w-[92px] bg-white/[0.03] border border-white/[0.08] rounded-xl p-3 text-sm font-medium focus:border-accent/40 outline-none transition-all text-white" />
                    <input ref={debugEpisodeRef} type="number" placeholder="Episode #" defaultValue="1" className="w-[100px] bg-white/[0.03] border border-white/[0.08] rounded-xl p-3 text-sm font-medium focus:border-accent/40 outline-none transition-all text-white" />
                    <select ref={debugProviderRef} defaultValue="allanime" className="flex-1 bg-white/[0.03] border border-white/[0.08] rounded-xl p-3 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white">
                      <option value="allanime" className="bg-[#121212]">AllAnime</option>
                      <option value="anineko" className="bg-[#121212]">AniNeko</option>
                    </select>
                    <button
                      onClick={() => {
                        const mediaId = debugMediaIdRef.current?.value;
                        const ep = debugEpisodeRef.current?.value;
                        const provider = debugProviderRef.current?.value;
                        if (!mediaId || !ep) return;
                        setDebugOutput("Loading...");
                        invoke<Record<string, unknown>>("debug_provider_streams", {
                          mediaId: parseInt(mediaId, 10),
                          episodeNumber: parseInt(ep, 10),
                          provider,
                        })
                          .then((data) => {
                            const raw = JSON.stringify(data, null, 2);
                            const finalStreams = (data?.final_streams as any[]) || [];
                            const debugPasses = (data?.debug_passes as any[]) || [];
                            const errors = (data?.errors as string[]) || [];
                            const pageTitle = data?.page_title || "";
                            const epNum = data?.episode ?? 0;
                            const lines: string[] = [];
                            if (finalStreams.length > 0) {
                              lines.push(`✅ ${finalStreams.length} stream(s) found`);
                            } else {
                              lines.push("❌ No streams found");
                            }
                            if (errors.length > 0) {
                              lines.push(`⚠️ ${errors.length} error(s): ${errors[0]}`);
                            }
                            if (debugPasses.length > 0) {
                              const fails = debugPasses.filter((p: any) => p.pass === "error" || p.pass !== "pass");
                              if (fails.length > 0) {
                                lines.push(`⚠️ ${fails.length} scraper pass(es) failed: ${fails[0]?.error || "unknown"}`);
                              }
                            }
                            if (pageTitle) lines.push(`📄 Page: ${pageTitle}`);
                            lines.push(`🔢 Episode: ${epNum}`);
                            if (data?.slug) lines.push(`🔗 Slug: ${data.slug}`);
                            const summary = lines.join("\n");
                            setDebugOutput(summary + "\n\n── Raw JSON ──\n" + raw);
                          })
                          .catch((err: unknown) => { setDebugOutput("Error: " + String(err)); });
                      }}
                      className="px-4 py-3 rounded-xl bg-accent hover:bg-accent-light text-white font-bold text-sm shadow-lg shadow-accent/20 transition-all active:scale-[0.98]"
                    >
                      Test
                    </button>
                  </div>
                  <div className="relative">
                    <pre className="w-full h-48 bg-black/40 rounded-xl p-3 text-[10px] font-mono text-gray-300 overflow-y-auto border border-white/5 whitespace-pre-wrap break-all">{debugOutput}</pre>
                    {debugOutput && (
                      <button
                        onClick={() => navigator.clipboard.writeText(debugOutput)}
                        className="absolute top-2 right-2 p-2 rounded-lg bg-white/[0.06] hover:bg-white/[0.12] text-gray-400 hover:text-white transition-all"
                        title="Copy output"
                      >
                        <Copy size={14} />
                      </button>
                    )}
                  </div>
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
                  className={`w-full py-3 rounded-xl text-sm font-bold transition-all ${
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
                  className={`w-full py-3 px-4 rounded-xl text-[10px] font-bold transition-all flex items-center justify-center space-x-2 ${
                    resetOnboardingState === "confirming"
                      ? "bg-red-500/20 text-red-400 border border-red-500/30"
                      : "bg-white/[0.03] hover:bg-white/[0.06] text-gray-400 border border-white/[0.08]"
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

function CardSection({ title, description, children }: { title: string; description?: string; children: React.ReactNode }) {
  return (
    <section className="rounded-2xl bg-white/[0.02] border border-white/[0.06]">
      <div className="px-6 pt-5 pb-4 border-b border-white/[0.05]">
        <h3 className="text-lg font-bold text-white">{title}</h3>
        {description && <p className="text-xs text-gray-500 mt-1">{description}</p>}
      </div>
      <div className="p-3 sm:p-4 space-y-1">{children}</div>
    </section>
  );
}

function SettingField({ label, description, children, stack }: { label: string; description?: string; children: React.ReactNode; stack?: boolean }) {
  return (
    <div className={`px-3 py-3.5 rounded-xl hover:bg-white/[0.015] transition-colors ${stack ? "space-y-3" : "flex flex-col sm:flex-row sm:items-center gap-4"}`}>
      <div className="flex-1 min-w-0">
        <label className="text-sm font-semibold text-white">{label}</label>
        {description && <p className="text-xs text-gray-500 mt-0.5 leading-relaxed">{description}</p>}
      </div>
      <div className={stack ? "" : "w-full sm:w-64 shrink-0"}>{children}</div>
    </div>
  );
}

