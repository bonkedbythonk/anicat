// @ts-nocheck

import { useState, useEffect, useRef, useCallback } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Loader2, CheckCircle2, Save, Cpu, PlayCircle, HardDrive, Globe, RotateCcw, XCircle, AlertCircle, Download, Search, Activity } from "lucide-react";
import { mediaApi, type HealthStatus, API_BASE_ORIGIN, dispatchRefresh } from "@/lib/api";
import { useAppStore } from "@/stores/app";
import type { UiStyle } from "@/hooks/useTheme";
import { ErrorBanner } from "@/components/ErrorBanner";

interface SettingsViewProps {
  health: HealthStatus | null;
  onUpdateStarted?: (message?: string) => void;
}

interface RegistryStats {
  registry?: {
    total_media_breakdown?: {
      total?: number;
    };
  };
  downloads?: {
    downloaded?: number;
  };
}

interface ConfigOptions {
  stream?: {
    quality?: string[];
    player_type?: string[];
  };
}

interface ScraperTestState {
  status: "idle" | "testing" | "success" | "failed";
  duration_ms?: number;
  result_count?: number;
  error?: string;
  results?: { id: string; title: string }[];
  streams?: any[];
  expanded?: boolean;
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
  const [activeTab, setActiveTab] = useState<"general" | "player" | "downloads" | "account" | "maintenance" | "scrapers">("general");
  const [registryStats, setRegistryStats] = useState<RegistryStats | null>(null);

  // Read default tab from store (set by Connect button on HomeView)
  useEffect(() => {
    const tab = useAppStore.getState().settingsDefaultTab;
    if (tab === "account" || tab === "maintenance" || tab === "scrapers") {
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
  const [options, setOptions] = useState<ConfigOptions | null>(null);
  const [authPending, setAuthPending] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [successMessage, setSuccessMessage] = useState<string | null>(null);
  const [autoSkip, setAutoSkip] = useState(false);
  const [theme, setTheme] = useState<"system" | "dark" | "light">("system");
  const [uiStyle, setUiStyle] = useState<UiStyle>("neon-abyss");
  const [fallingParticles, setFallingParticles] = useState(true);
  const hasUpdate = Boolean(health?.update_available || stagedHasUpdate);

  const [testQuery, setTestQuery] = useState("Naruto");
  const [scraperStates, setScraperStates] = useState<Record<string, ScraperTestState>>({
    anineko: { status: "idle" },
    mangakatana: { status: "idle" },
  });

  const handleTestScraper = async (name: string, isManga: boolean) => {
    setScraperStates(prev => ({
      ...prev,
      [name]: { ...prev[name], status: "testing", error: undefined, results: undefined }
    }));

    try {
      const res = await mediaApi.testProvider(name, isManga, testQuery);
      setScraperStates(prev => ({
        ...prev,
        [name]: {
          status: res.status === "success" ? "success" : "failed",
          duration_ms: res.duration_ms,
          result_count: res.result_count,
          error: res.error,
          results: res.results,
          streams: res.streams,
          expanded: prev[name]?.expanded ?? false
        }
      }));
    } catch (err: any) {
      setScraperStates(prev => ({
        ...prev,
        [name]: {
          status: "failed",
          error: err?.message || String(err)
        }
      }));
    }
  };

  const handleTestAll = () => {
    const list = [
      { name: "anineko", isManga: false },
      { name: "mangakatana", isManga: true },
    ];
    list.forEach(item => {
      handleTestScraper(item.name, item.isManga);
    });
  };

  const renderScraperCard = (name: string, displayName: string, isManga: boolean) => {
    const state = scraperStates[name] || { status: "idle" };
    
    return (
      <div 
        key={name}
        className="p-5 rounded-2xl bg-white/[0.02] border border-white/[0.06] hover:border-white/[0.1] transition-all flex flex-col justify-between space-y-4"
      >
        <div className="flex items-start justify-between">
          <div className="space-y-1">
            <div className="font-bold text-white text-sm lg:text-base">{displayName}</div>
            <div className="text-[10px] text-gray-500 uppercase tracking-wider">{isManga ? "Manga Scraper" : "Anime Scraper"}</div>
            
            {state.status === "success" && (
              <div className="flex items-center space-x-2 mt-1.5 text-xs text-green-400 font-semibold animate-fade-in">
                <CheckCircle2 size={13} />
                <span>{state.duration_ms ? `${state.duration_ms}ms` : "Success"}</span>
                <span className="text-gray-600">•</span>
                <span>{state.result_count ?? 0} results</span>
              </div>
            )}
            
            {state.status === "failed" && (
              <div className="flex items-center space-x-2 mt-1.5 text-xs text-red-400 font-semibold animate-fade-in">
                <AlertCircle size={13} />
                <span>{state.duration_ms ? `${state.duration_ms}ms` : "Error"}</span>
              </div>
            )}
          </div>

          <div className="flex items-center space-x-2">
            {state.status === "idle" && (
              <span className="px-2 py-1 rounded-md text-[10px] font-bold bg-white/[0.04] text-gray-500 border border-white/[0.02]">
                Idle
              </span>
            )}
            {state.status === "testing" && (
              <span className="px-2 py-1 rounded-md text-[10px] font-bold bg-yellow-500/10 text-yellow-400 border border-yellow-500/20 animate-pulse flex items-center space-x-1">
                <Loader2 size={10} className="animate-spin" />
                <span>Testing</span>
              </span>
            )}
            {state.status === "success" && (
              <span className="px-2 py-1 rounded-md text-[10px] font-bold bg-green-500/10 text-green-400 border border-green-500/20">
                Success
              </span>
            )}
            {state.status === "failed" && (
              <span className="px-2 py-1 rounded-md text-[10px] font-bold bg-red-500/10 text-red-400 border border-red-500/20">
                Failed
              </span>
            )}
            
            <button
              onClick={() => handleTestScraper(name, isManga)}
              disabled={state.status === "testing"}
              className="px-3 py-1.5 rounded-lg bg-white/[0.04] hover:bg-white/[0.08] border border-white/[0.06] text-white text-xs font-bold transition-all disabled:opacity-50"
            >
              Test
            </button>
          </div>
        </div>

        {state.status === "failed" && state.error && (
          <div className="p-3.5 rounded-xl bg-red-500/5 border border-red-500/10 text-[11px] text-red-400/90 font-mono whitespace-pre-wrap break-words leading-relaxed animate-fade-in">
            <div className="font-bold text-red-400 mb-1 text-[9px] uppercase tracking-wider">Error Details</div>
            {state.error}
          </div>
        )}

        {state.status === "success" && state.results && state.results.length > 0 && (
          <div className="space-y-2">
            <button
              onClick={() => {
                setScraperStates(prev => ({
                  ...prev,
                  [name]: { ...prev[name], expanded: !prev[name]?.expanded }
                }));
              }}
              className="text-[10px] font-bold text-accent hover:underline flex items-center space-x-1"
            >
              <span>{state.expanded ? "Hide Results" : `Inspect Results (${state.results.length})`}</span>
            </button>
            
            {state.expanded && (
              <div className="p-3.5 rounded-xl bg-black/30 border border-white/[0.04] space-y-3.5 animate-fade-in max-w-full">
                <div>
                  <div className="text-[9px] font-bold text-gray-500 uppercase tracking-wider pb-1.5 border-b border-white/[0.04] mb-1.5">Top Matches</div>
                  <div className="space-y-2">
                    {state.results.map((res, i) => (
                      <div key={i} className="flex items-start justify-between text-xs text-gray-300 gap-2">
                        <span className="font-medium truncate flex-1">{res.title || "Unknown Title"}</span>
                        <span className="text-[10px] text-gray-600 font-mono shrink-0 bg-white/[0.02] px-1.5 py-0.5 rounded border border-white/[0.04]">{res.id}</span>
                      </div>
                    ))}
                  </div>
                </div>

                {state.streams && state.streams.length > 0 && (
                  <div className="pt-3 border-t border-white/[0.04] space-y-2.5">
                    <div className="text-[9px] font-bold text-gray-500 uppercase tracking-wider">
                      Streams for EP {state.streams[0].episode} of first match
                    </div>
                    <div className="space-y-3 max-h-[300px] overflow-y-auto pr-1">
                      {state.streams.map((stream: any, idx: number) => (
                        <div key={idx} className="p-2.5 rounded-xl bg-white/[0.01] border border-white/[0.04] space-y-2 text-[10px] text-gray-300">
                          <div className="flex items-center justify-between">
                            <span className="font-bold text-white text-xs">{(stream.name || "").trim()}</span>
                            <span className="px-1.5 py-0.5 rounded bg-green-500/10 text-green-400 border border-green-500/20 text-[9px] font-black">
                              {stream.is_m3u8 ? "HLS" : "Direct"}
                            </span>
                          </div>
                          
                          <div className="space-y-2">
                            <div className="flex items-center justify-between text-[9px] text-gray-500">
                              <span>{stream.group?.replace(/_/g, " ") || "unknown"} &bull; {stream.quality || "HD"}</span>
                              <span className="font-mono bg-white/[0.02] px-1 rounded border border-white/[0.04]">{stream.source_type}</span>
                            </div>
                            <div className="font-mono text-[9px] text-accent truncate bg-black/20 p-2 rounded select-all cursor-pointer hover:bg-accent/5 transition-colors">
                              {stream.url}
                            </div>
                          </div>
                        </div>
                      ))}
                    </div>
                  </div>
                )}
              </div>
            )}
          </div>
        )}
        
        {state.status === "success" && state.results && state.results.length === 0 && (
          <div className="p-3 rounded-xl bg-yellow-500/5 border border-yellow-500/10 text-[11px] text-yellow-500/80 font-medium animate-fade-in">
            Search query succeeded but returned 0 results.
          </div>
        )}
      </div>
    );
  };


  useEffect(() => {
    if (typeof window !== "undefined") {
      const savedAutoSkip = localStorage.getItem("anicat_auto_skip");
      const savedTheme = localStorage.getItem("anicat_theme") as "system" | "dark" | "light" | null;
      const savedStyle = localStorage.getItem("anicat_ui_style") as UiStyle | null;
      const savedFalling = localStorage.getItem("anicat_falling_particles");

      setTimeout(() => {
        setAutoSkip(savedAutoSkip === "true");
        if (savedTheme) {
          setTheme(savedTheme);
        }
        if (savedStyle) {
          setUiStyle(savedStyle);
        }
        setFallingParticles(savedFalling !== "false");
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

  useEffect(() => {
    mediaApi.getConfig()
      .then(setConfig)
      .catch(console.error)
      .finally(() => setLoading(false));
    // Fetch server-supported option lists for UI selects
    mediaApi.getConfigOptions().then(setOptions).catch(() => {/* ignore */ });
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
          setStagedHasUpdate(res.update_available);
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

  const handleBranchChange = async (newBranch: string) => {
    if (!config) return;
    const updated = {
      ...config,
      general: {
        ...config.general,
        update_branch: newBranch
      }
    };
    setConfig(updated);
    setStagedHasUpdate(false);
    setUpdateMessage({ text: "", type: null });
    try {
      await mediaApi.updateConfig({
        general: {
          update_branch: newBranch
        }
      });
    } catch (err) {
      console.error("Failed to save branch change:", err);
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

  useEffect(() => {
    if (activeTab === "maintenance" && !registryStats) {
      mediaApi.getRegistryStats().then(setRegistryStats).catch(console.error);
    }
  }, [activeTab, registryStats]);

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
    { id: "downloads", label: "Downloads", icon: HardDrive },
    { id: "account", label: "Account", icon: Globe },
    { id: "maintenance", label: "Maintenance", icon: RotateCcw },
    { id: "scrapers", label: "Scrapers", icon: Search },
  ] as const;

  return (
    <div className="space-y-6 animate-fade-in max-w-3xl">
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

      {/* Horizontal tab bar — easier to scan than sidebar */}
      <div className="flex space-x-1 bg-white/[0.02] p-1 rounded-xl border border-white/[0.06] overflow-x-auto scrollbar-hide">
        {tabs.map((tab) => (
          <button
            key={tab.id}
            onClick={() => setActiveTab(tab.id)}
            className={`flex items-center space-x-2 px-4 py-2.5 rounded-lg font-semibold text-sm whitespace-nowrap transition-all flex-1 justify-center ${
              activeTab === tab.id
                ? "bg-accent text-white shadow-lg shadow-accent/20"
                : "text-gray-500 hover:text-white hover:bg-white/[0.04]"
            }`}
          >
            <tab.icon size={16} />
            <span>{tab.label}</span>
          </button>
        ))}
      </div>

        {/* Settings form */}
        <div className="space-y-6">
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
                          <div className="flex-1 h-8 rounded-lg" style={{ background: "rgba(28,28,30,0.6)", border: "1px solid rgba(255,255,255,0.08)" }} />
                          <div className="flex-1 h-5 rounded-lg" style={{ background: "rgba(10,132,255,0.3)", border: "1px solid rgba(10,132,255,0.4)" }} />
                        </div>
                      </div>
                      <div className="px-3 py-2 bg-white/[0.02]">
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
                          <div className="flex-1 h-5 rounded-xl" style={{ background: "rgba(232,160,180,0.25)", border: "1px solid rgba(232,160,180,0.4)" }} />
                        </div>
                      </div>
                      <div className="px-3 py-2" style={{ background: "rgba(244,180,196,0.04)" }}>
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
                          <div className="flex-1 h-5 rounded" style={{ background: "#e8272c", border: "2px solid #1a1a1a" }} />
                        </div>
                      </div>
                      <div className="px-3 py-2" style={{ background: "rgba(232, 39, 44, 0.04)" }}>
                        <div className="text-xs font-bold" style={{ color: "#e8272c" }}>Retro Manga</div>
                        <div className="text-[10px] mt-0.5 text-gray-500">Halftone dot / Manga panel style</div>
                      </div>
                      {uiStyle === "retro-manga" && (
                        <div className="absolute top-2 right-2 w-4 h-4 rounded-full flex items-center justify-center" style={{ background: "#e8272c" }}>
                          <svg width="8" height="8" viewBox="0 0 8 8" fill="none"><path d="M1 4l2 2 4-4" stroke="white" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/></svg>
                        </div>
                      )}
                    </button>

                    {/* Forest Moss */}
                    <button
                      onClick={() => handleStyleChange("forest-moss")}
                      className={`relative rounded-2xl overflow-hidden border-2 transition-all text-left ${
                        uiStyle === "forest-moss"
                          ? "border-[#10b981] shadow-lg shadow-[#10b981]/20"
                          : "border-white/[0.06] hover:border-white/[0.15]"
                      }`}
                    >
                      {/* Preview swatch */}
                      <div className="h-20 w-full" style={{ background: "linear-gradient(135deg, #050f0b 0%, #0a1a12 60%, #123021 100%)" }}>
                        <div className="flex gap-1 p-2 h-full items-end">
                          <div className="flex-1 h-8 rounded-lg" style={{ background: "rgba(18,48,33,0.6)", border: "1px solid rgba(52,211,153,0.15)" }} />
                          <div className="flex-1 h-5 rounded-lg" style={{ background: "rgba(16,185,129,0.3)", border: "1px solid rgba(16,185,129,0.4)" }} />
                        </div>
                      </div>
                      <div className="px-3 py-2" style={{ background: "rgba(16, 185, 129, 0.04)" }}>
                        <div className="text-xs font-bold" style={{ color: "#10b981" }}>Forest Moss</div>
                        <div className="text-[10px] mt-0.5 text-gray-500">Organic green / Fresh woodland</div>
                      </div>
                      {uiStyle === "forest-moss" && (
                        <div className="absolute top-2 right-2 w-4 h-4 rounded-full flex items-center justify-center" style={{ background: "#10b981" }}>
                          <svg width="8" height="8" viewBox="0 0 8 8" fill="none"><path d="M1 4l2 2 4-4" stroke="white" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/></svg>
                        </div>
                      )}
                    </button>
                  </div>
                </SettingField>

                <SettingField
                  label="Falling Leaves/Petals"
                  description="Toggle the background falling leaves/petals animation for Sakura Zen and Forest Moss themes."
                >
                  <select
                    value={fallingParticles ? "true" : "false"}
                    onChange={(e) => {
                      const val = e.target.value === "true";
                      setFallingParticles(val);
                      localStorage.setItem("anicat_falling_particles", String(val));
                      window.dispatchEvent(new Event("anicat_settings_changed"));
                    }}
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
                  >
                    <option value="true">Enabled</option>
                    <option value="false">Disabled</option>
                  </select>
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

              <CardSection title="Integrations">
                <SettingField
                  label="Discord Rich Presence"
                  description="Enable Discord Rich Presence to show your current activity."
                >
                  <select
                    value={config.general?.discord ? "true" : "false"}
                    onChange={(e) => updateField("general", "discord", e.target.value === "true")}
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
                  >
                    <option value="false">Disabled</option>
                    <option value="true">Enabled</option>
                  </select>
                </SettingField>
              </CardSection>

              <CardSection title="Content Sources">
                <SettingField
                  label="Anime Provider"
                  description="Primary source for streaming video."
                >
                  <select
                    value={String(config.general?.provider || "anineko")}
                    onChange={(e) => updateField("general", "provider", e.target.value)}
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
                  >
                    <option value="anineko">AniNeko</option>
                  </select>
                </SettingField>

                <SettingField
                  label="Fallback Providers"
                  description="Only one provider is configured. Fallbacks are not needed."
                >
                  <p className="text-xs text-muted-foreground">No fallbacks available.</p>
                </SettingField>

                <SettingField
                  label="Manga Provider"
                  description="Source for manga chapters."
                >
                  <select
                    value={String(config.general?.manga_provider || "mangakatana")}
                    onChange={(e) => updateField("general", "manga_provider", e.target.value)}
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
                  >
                    <option value="mangakatana">MangaKatana</option>
                  </select>
                </SettingField>

                <SettingField
                  label="Search & Tracking API"
                  description="Source for anime search, lists, and metadata."
                >
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
                <SettingField label="Quality" description="Preferred resolution.">
                  <select
                    value={String(config.stream?.quality || "1080")}
                    onChange={(e) => updateField("stream", "quality", e.target.value)}
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
                  >
                    {(options?.stream?.quality ?? ["1080", "720", "480", "360"]).map((q: string) => (
                      <option key={q} value={q}>{q.endsWith('p') ? q : `${q}p`}</option>
                    ))}
                  </select>
                </SettingField>

                <SettingField label="Audio" description="Sub or dub.">
                  <select
                    value={String(config.stream?.translation_type || "sub")}
                    onChange={(e) => updateField("stream", "translation_type", e.target.value)}
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
                  >
                    <option value="sub">Subtitled (Japanese)</option>
                    <option value="dub">Dubbed (English)</option>
                  </select>
                </SettingField>

                <SettingField label="Skip Intro" description="Automatically skip opening and ending credits using AniSkip times.">
                  <select
                    value={autoSkip ? "true" : "false"}
                    onChange={(e) => {
                      const val = e.target.value === "true";
                      setAutoSkip(val);
                      localStorage.setItem("anicat_auto_skip", String(val));
                    }}
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
                  >
                    <option value="false">Manual (Show Skip Intro button)</option>
                    <option value="true">Automatic (skip without prompt)</option>
                  </select>
                </SettingField>
              </CardSection>

              <CardSection title="Video Player">
                <SettingField label="GPU Upscaling" description="Anime4K upscaling for the external player.">
                  <select
                    value={String(config.stream?.shader_profile || "balanced")}
                    onChange={(e) => updateField("stream", "shader_profile", e.target.value)}
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
                  >
                    <option value="balanced">On</option>
                    <option value="off">Off</option>
                  </select>
                </SettingField>

                <SettingField label="Auto-Play Trailers" description="Play muted background trailer videos on featured and detail pages (may cause configuration errors in Tauri).">
                  <select
                    value={config.stream?.autoplay_trailers ? "true" : "false"}
                    onChange={(e) => updateField("stream", "autoplay_trailers", e.target.value === "true")}
                    className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white"
                  >
                    <option value="false">Disabled</option>
                    <option value="true">Enabled</option>
                  </select>
                </SettingField>
              </CardSection>
            </div>
          )}

          {activeTab === "downloads" && (
            <div className="space-y-6 animate-fade-in">
              <CardSection title="Storage">
                <SettingField label="Download Location" description="Where downloaded media is saved on disk.">
                  <div className="relative">
                    <HardDrive size={16} className="absolute left-4 top-1/2 -translate-y-1/2 text-gray-600" />
                    <input
                      type="text"
                      value={String(config.downloads?.downloads_dir || "")}
                      onChange={(e) => updateField("downloads", "downloads_dir", e.target.value)}
                      className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl py-3.5 pl-11 pr-4 text-sm font-medium focus:border-accent/40 outline-none transition-all"
                    />
                  </div>
                </SettingField>
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
                        id="logout-btn"
                        data-confirmed="false"
                        onClick={async () => {
                          const btn = document.getElementById('logout-btn');
                          if (btn?.getAttribute('data-confirmed') === 'true') {
                            if (btn) {
                              btn.innerHTML = '<span>Logging out...</span>';
                              btn.setAttribute('disabled', 'true');
                              btn.className = "mt-2 text-xs font-bold text-red-400/40 flex items-center space-x-1 w-full justify-center";
                            }
                            mediaApi.updateConfig({ anilist: { token: "" } })
                              .then(() => {
                                localStorage.removeItem("anicat-query-cache");
                                window.location.reload();
                              })
                              .catch(() => {
                                if (btn) {
                                  btn.removeAttribute('disabled');
                                  btn.setAttribute('data-confirmed', 'false');
                                  btn.innerHTML = '<span>Logout</span>';
                                  btn.className = "mt-2 text-xs font-bold text-red-400/60 hover:text-red-400 flex items-center space-x-1 w-full justify-center";
                                }
                              });
                          } else {
                            if (btn) {
                              btn.setAttribute('data-confirmed', 'true');
                              btn.innerHTML = '<span>Are you sure? Click again</span>';
                              btn.className = "mt-2 text-xs font-bold text-red-400 hover:text-red-300 flex items-center space-x-1 w-full justify-center";
                            }
                          }
                        }}
                        className="mt-2 text-xs font-bold text-red-400/60 hover:text-red-400 flex items-center space-x-1 w-full justify-center"
                      >
                        <span>Logout</span>
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
                  <SettingField label="Update Channel" description="">
                    <select
                      value={String(config.general?.update_branch || "stable")}
                      onChange={(e) => handleBranchChange(e.target.value)}
                      className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all appearance-none cursor-pointer text-white animate-fade-in"
                    >
                      <option value="stable" className="bg-[#121212] text-white">Stable (official releases)</option>
                      <option value="nightly" className="bg-[#121212] text-white">Nightly (early access)</option>
                    </select>
                  </SettingField>

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

              {/* Registry */}
              <CardSection title="Registry" description="Offline metadata, progress, and download tracking.">
                {registryStats && (
                  <div className="grid grid-cols-2 gap-3">
                    <div className="p-4 rounded-xl bg-white/[0.02] border border-white/[0.06]">
                      <div className="text-[10px] font-bold text-gray-500 uppercase tracking-wider mb-1">Total Media</div>
                      <div className="text-2xl font-extrabold text-white">
                        {registryStats.registry?.total_media_breakdown?.total || 0}
                      </div>
                    </div>
                    <div className="p-4 rounded-xl bg-white/[0.02] border border-white/[0.06]">
                      <div className="text-[10px] font-bold text-gray-500 uppercase tracking-wider mb-1">Downloaded</div>
                      <div className="text-2xl font-extrabold text-white">
                        {registryStats.downloads?.downloaded || 0}
                      </div>
                    </div>
                  </div>
                )}
                <div className="flex space-x-3 pt-2">
                  <button
                    onClick={handleBackup}
                    disabled={backingUp}
                    className="flex-1 flex items-center justify-center space-x-2 py-2.5 rounded-xl bg-white/[0.04] hover:bg-white/[0.07] text-gray-300 transition-all font-bold text-sm disabled:opacity-50 border border-white/[0.06]"
                  >
                    {backingUp ? <Loader2 size={15} className="animate-spin" /> : <Save size={15} />}
                    <span>{backingUp ? "Creating..." : "Backup"}</span>
                  </button>
                  {backupUrl && (
                    <a
                      href={backupUrl}
                      download
                      className="flex-1 flex items-center justify-center space-x-2 py-2.5 rounded-xl bg-green-500/20 text-green-400 border border-green-500/30 hover:bg-green-500/30 transition-all font-bold text-sm"
                    >
                      <Download size={15} />
                      <span>Download Backup</span>
                    </a>
                  )}
                </div>
              </CardSection>

              {/* Logs */}
              <CardSection title="Logs & Debugging">
                <button
                  onClick={handleOpenLogs}
                  className="w-full py-2.5 bg-white/[0.04] hover:bg-white/[0.07] text-white/70 rounded-xl text-xs font-bold transition-all border border-white/5 flex items-center justify-center space-x-2"
                >
                  <HardDrive size={14} />
                  <span>Open Log Directory</span>
                </button>
                <button
                  onClick={async () => {
                    try {
                      const logs = await mediaApi.getLogs(50);
                      const report = [
                        `Anicat Version: ${health?.current_version || "unknown"}`,
                        `Platform: ${window.navigator.platform}`,
                        `User Agent: ${window.navigator.userAgent}`,
                        `API Connected: ${health?.api_connected}`,
                        `API Authenticated: ${health?.api_authenticated}`,
                        `Is Offline: ${health?.is_offline}`,
                        `Data Version: ${health?.data_version}`,
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
                <pre className="w-full h-40 bg-black/40 rounded-xl p-3 text-[10px] font-mono text-gray-500 overflow-y-auto scrollbar-hide border border-white/5">
                  <LogViewer />
                </pre>
              </CardSection>

              {/* Danger Zone */}
              <CardSection title="Danger Zone" description="Irreversible actions.">
                <button
                  id="clear-registry-btn"
                  data-confirmed="false"
                  onClick={() => {
                    const btn = document.getElementById('clear-registry-btn');
                    if (btn?.getAttribute('data-confirmed') === 'true') {
                      if (btn) {
                        btn.innerHTML = 'Wiping Registry...';
                        btn.setAttribute('disabled', 'true');
                        btn.className = "w-full py-3 bg-red-500/10 text-red-400/40 rounded-xl text-sm font-bold transition-all border border-red-500/10 cursor-not-allowed pointer-events-none";
                      }
                      mediaApi.wipeRegistry().then(() => {
                        if (btn) {
                          btn.innerHTML = 'Registry Wiped! Restarting...';
                          btn.className = "w-full py-3 bg-green-500/20 text-green-400 rounded-xl text-sm font-bold transition-all border border-green-500/30";
                          setTimeout(() => window.location.reload(), 1500);
                        }
                      }).catch((err) => {
                        console.error("Wipe failed:", err);
                        if (btn) {
                          btn.removeAttribute('disabled');
                          btn.setAttribute('data-confirmed', 'false');
                          btn.innerHTML = 'Clear Local Registry';
                          btn.className = "w-full py-3 border border-red-500/20 text-red-400/60 rounded-xl text-sm font-bold hover:bg-red-500/10 transition-all";
                        }
                      });
                    } else {
                      if (btn) {
                        btn.setAttribute('data-confirmed', 'true');
                        btn.innerHTML = 'Are you sure? This will wipe your history!';
                        btn.className = "w-full py-3 bg-red-500/20 text-red-400 rounded-xl text-sm font-bold transition-all border border-red-500/30";
                      }
                    }
                  }}
                  className="w-full py-3 border border-red-500/20 text-red-400/60 rounded-xl text-sm font-bold hover:bg-red-500/10 transition-all"
                >
                  Clear Local Registry
                </button>
                <button
                  onClick={() => {
                    const btn = document.getElementById('reset-onboarding-btn');
                    if (btn?.getAttribute('data-confirmed') === 'true') {
                      localStorage.removeItem("anicat_onboarding_seen");
                      window.location.reload();
                    } else {
                      if (btn) {
                        btn.setAttribute('data-confirmed', 'true');
                        btn.innerHTML = '<span>Are you sure? Click again to Reset</span>';
                        btn.className = "w-full py-3 px-4 rounded-xl bg-red-500/20 text-red-400 text-[10px] font-bold transition-all border border-red-500/30 flex items-center justify-center space-x-2";
                      }
                    }
                  }}
                  id="reset-onboarding-btn"
                  data-confirmed="false"
                  className="w-full py-3 px-4 rounded-xl bg-white/[0.03] hover:bg-white/[0.06] text-gray-400 text-[10px] font-bold transition-all border border-white/[0.08] flex items-center justify-center space-x-2"
                >
                  <RotateCcw size={12} />
                  <span>Reset Onboarding Setup</span>
                </button>
              </CardSection>
            </div>
          )}

          {activeTab === "scrapers" && (
            <div className="space-y-6 animate-fade-in">
              <CardSection 
                title="Scraper Tester" 
                description="Test the connection and search accuracy of configured anime and manga search scrapers in real-time."
              >
                <div className="flex flex-col sm:flex-row gap-3 items-end p-5 rounded-xl bg-white/[0.02] border border-white/[0.04]">
                  <div className="flex-1 space-y-2">
                    <label className="text-xs font-bold text-accent uppercase tracking-wider">Test Search Query</label>
                    <div className="relative">
                      <Search size={16} className="absolute left-4 top-1/2 -translate-y-1/2 text-gray-600" />
                      <input
                        type="text"
                        value={testQuery}
                        onChange={(e) => setTestQuery(e.target.value)}
                        placeholder="Search query to test..."
                        className="w-full bg-white/[0.03] border border-white/[0.08] rounded-xl py-3.5 pl-11 pr-4 text-sm font-medium focus:border-accent/40 outline-none transition-all text-white"
                      />
                    </div>
                  </div>
                  <button
                    onClick={handleTestAll}
                    className="w-full sm:w-auto px-6 py-3.5 rounded-xl bg-accent hover:bg-accent-light text-white font-bold text-sm shadow-lg shadow-accent/20 transition-all whitespace-nowrap active:scale-[0.98]"
                  >
                    Test All Scrapers
                  </button>
                </div>
              </CardSection>

              <div className="space-y-6">
                <div>
                  <h2 className="text-lg font-bold text-white mb-3">Anime Scrapers</h2>
                  <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    {renderScraperCard("anineko", "AniNeko", false)}
                  </div>
                </div>

                <div>
                  <h2 className="text-lg font-bold text-white mb-3">Manga Scrapers</h2>
                  <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                    {renderScraperCard("mangakatana", "MangaKatana", true)}
                  </div>
                </div>
              </div>
            </div>
          )}
        </div>
    </div>
  );
}

function LogViewer() {
  const [logs, setLogs] = useState<string>("");

  useEffect(() => {
    const fetchLogs = async () => {
      try {
        const res = await mediaApi.getLogs(50);
        setLogs(res.logs);
      } catch {
        setLogs("Could not fetch logs.");
      }
    };

    fetchLogs();
    const interval = setInterval(fetchLogs, 5000);
    return () => clearInterval(interval);
  }, []);

  return <div className="mt-2 text-gray-400 whitespace-pre-wrap">{logs}</div>;
}

function CardSection({ title, description, children }: { title: string; description?: string; children: React.ReactNode }) {
  return (
    <div className="p-5 rounded-2xl bg-white/[0.02] border border-white/[0.06] space-y-4">
      <div className="pb-3 border-b border-white/[0.04]">
        <h3 className="text-base font-bold text-white">{title}</h3>
        {description && <p className="text-xs text-gray-500 mt-0.5">{description}</p>}
      </div>
      {children}
    </div>
  );
}

function SettingField({ label, description, children }: { label: string; description?: string; children: React.ReactNode }) {
  return (
    <div className="space-y-2.5 p-5 rounded-xl bg-white/[0.02] border border-white/[0.04]">
      <label className="text-xs font-bold text-accent uppercase tracking-wider">{label}</label>
      {children}
      {description && <p className="text-[11px] text-gray-600">{description}</p>}
    </div>
  );
}
