import { useState, useEffect } from "react";
import { invoke } from "@tauri-apps/api/core";
import {
  Loader2,
  CheckCircle2,
  Globe,
  ArrowRight,
  Monitor,
  Download,
  ShieldAlert,
  Clock,
  Sparkles,
  Palette,
  Gauge
} from "lucide-react";
import { mediaApi, dispatchRefresh } from "@/lib/api";
import { useAppStore } from "@/stores/app";

interface OnboardingProps {
  onComplete: () => void;
}

export function Onboarding({ onComplete }: OnboardingProps) {
  const [step, setStep] = useState(1);
  const [tokenInput, setTokenInput] = useState("");
  const [validating, setValidating] = useState(false);
  const [connectedUser, setConnectedUser] = useState<string | null>(null);
  const [authError, setAuthError] = useState<string | null>(null);
  const [theme, setTheme] = useState<"system" | "dark" | "light">("system");
  const [uiStyle, setUiStyle] = useState<"neon-abyss" | "sakura-zen" | "retro-manga">("neon-abyss");
  const [timeFormat, setTimeFormat] = useState<"12h" | "24h">("24h");
  const [gpuUpscaling, setGpuUpscaling] = useState<"on" | "off">("on");
  const [interpolation, setInterpolation] = useState<"on" | "off">("off");
  const [translationType, setTranslationType] = useState<"sub" | "dub">("sub");
  const [authPending, setAuthPending] = useState(false);

  useEffect(() => {
    const savedStyle = (localStorage.getItem("anicat_ui_style") as "neon-abyss" | "sakura-zen" | "retro-manga" | null) || "neon-abyss";
    setUiStyle(savedStyle);
  }, []);

  useEffect(() => {
    mediaApi.getConfig().then((cfg) => {
      if (cfg?.stream?.shader_profile === "on" || cfg?.stream?.shader_profile === "off") {
        setGpuUpscaling(cfg.stream.shader_profile);
      }
      if (cfg?.stream?.interpolation === "on" || cfg?.stream?.interpolation === "off") {
        setInterpolation(cfg.stream.interpolation);
      }
      if (cfg?.general?.time_format === "12h" || cfg?.general?.time_format === "24h") {
        setTimeFormat(cfg.general.time_format);
      }
      if (cfg?.stream?.translation_type === "sub" || cfg?.stream?.translation_type === "dub") {
        setTranslationType(cfg.stream.translation_type);
      }
    }).catch(() => {});
  }, []);

  const handleGpuUpscalingChange = async (val: "on" | "off") => {
    setGpuUpscaling(val);
    try {
      await mediaApi.updateConfig({ stream: { shader_profile: val } });
    } catch {}
  };

  const handleInterpolationChange = async (val: "on" | "off") => {
    setInterpolation(val);
    try {
      await mediaApi.updateConfig({ stream: { interpolation: val } });
    } catch {}
  };

  const handleTranslationTypeChange = async (val: "sub" | "dub") => {
    setTranslationType(val);
    try {
      await mediaApi.updateConfig({ stream: { translation_type: val } });
    } catch {}
  };

  const handleTokenChange = async (val: string) => {
    setTokenInput(val);
    const hashMatch = val.match(/#.*access_token=([^&]+)/);
    const token = hashMatch ? decodeURIComponent(hashMatch[1]) : val.trim();
    
    if (token.length > 20) {
      setValidating(true);
      setAuthError(null);
      try {
        await mediaApi.updateConfig({ api: { anilist_token: token } });
        const healthData = await invoke<{
          authenticated: boolean;
          connected: boolean;
          offline: boolean;
          auth_error: string | null;
          token_present: boolean;
          viewer_name: string | null;
        }>("check_health");
        
        if (healthData.authenticated && healthData.viewer_name) {
          setConnectedUser(healthData.viewer_name);
          useAppStore.getState().setHealthState({
            connected: healthData.connected,
            authenticated: healthData.authenticated,
            offline: healthData.offline,
            authError: healthData.auth_error,
            tokenPresent: healthData.token_present,
          });
          dispatchRefresh();
          window.dispatchEvent(new Event("anicat_health_recheck"));
          setTimeout(() => setStep(3), 1500);
        } else {
          setAuthError(healthData.auth_error || "Invalid token or authorization rejected.");
        }
      } catch (err) {
        setAuthError("Failed to validate token. Check network settings.");
      } finally {
        setValidating(false);
      }
    }
  };

  const handleThemeChange = (newTheme: "system" | "dark" | "light") => {
    setTheme(newTheme);
    localStorage.setItem("anicat_theme", newTheme);
    const isDarkSystem = window.matchMedia("(prefers-color-scheme: dark)").matches;
    document.documentElement.classList.remove("light", "dark", "system");
    document.documentElement.classList.add(newTheme);
    if (newTheme === "light" || (newTheme === "system" && !isDarkSystem)) {
      document.documentElement.classList.add("light");
    } else {
      document.documentElement.classList.add("dark");
    }
    window.dispatchEvent(new StorageEvent("storage", { key: "anicat_theme", newValue: newTheme }));
  };

  const handleUiStyleChange = (style: "neon-abyss" | "sakura-zen" | "retro-manga") => {
    setUiStyle(style);
    localStorage.setItem("anicat_ui_style", style);
    document.documentElement.setAttribute("data-style", style);
    document.documentElement.classList.add("theme-transition");

    const SAKURA_ZEN_FONT_URL = "https://fonts.googleapis.com/css2?family=Noto+Serif+JP:wght@400;600;700&display=swap";
    const RETRO_MANGA_FONT_URL = "https://fonts.googleapis.com/css2?family=Bangers&family=Noto+Sans+JP:wght@400;700&display=swap";

    const existingSakura = document.getElementById("font-noto-serif-jp");
    const existingRetro = document.getElementById("font-retro-manga");
    if (existingSakura) existingSakura.remove();
    if (existingRetro) existingRetro.remove();

    if (style === "sakura-zen") {
      const link = document.createElement("link");
      link.id = "font-noto-serif-jp";
      link.rel = "stylesheet";
      link.href = SAKURA_ZEN_FONT_URL;
      document.head.appendChild(link);
    } else if (style === "retro-manga") {
      const link = document.createElement("link");
      link.id = "font-retro-manga";
      link.rel = "stylesheet";
      link.href = RETRO_MANGA_FONT_URL;
      document.head.appendChild(link);
    }

    window.dispatchEvent(new StorageEvent("storage", { key: "anicat_ui_style", newValue: style }));

    setTimeout(() => {
      document.documentElement.classList.remove("theme-transition");
    }, 400);
  };

  const handleTimeFormatChange = async (format: "12h" | "24h") => {
    setTimeFormat(format);
    localStorage.setItem("anicat_time_format", format);
    try {
      await mediaApi.updateConfig({ general: { time_format: format } });
    } catch {}
  };

  const handleFinish = () => {
    localStorage.setItem("anicat_onboarding_seen", "true");
    onComplete();
  };

  return (
    <div className="fixed inset-0 z-[999] flex items-center justify-center bg-background/95 animate-fade-in p-4">
      <div className="relative w-full max-w-lg bg-card border border-border rounded-lg p-8 shadow-xl shadow-black/20 flex flex-col space-y-6 max-h-[90vh] overflow-y-auto scrollbar-hide">
        
        {/* Step Indicators */}
        <div className="flex justify-center space-x-2.5">
          <div className={`h-1.5 rounded-full transition-all duration-300 ${step === 1 ? "w-8 bg-accent" : "w-2.5 bg-border"}`} />
          <div className={`h-1.5 rounded-full transition-all duration-300 ${step === 2 ? "w-8 bg-accent" : "w-2.5 bg-border"}`} />
          <div className={`h-1.5 rounded-full transition-all duration-300 ${step === 3 ? "w-8 bg-accent" : "w-2.5 bg-border"}`} />
          <div className={`h-1.5 rounded-full transition-all duration-300 ${step === 4 ? "w-8 bg-accent" : "w-2.5 bg-border"}`} />
        </div>

        {/* Step 1: Welcome Screen */}
        {step === 1 && (
          <div className="space-y-6 text-center animate-fade-in">
            <div className="flex justify-center">
              <img src="/anicat_logo.png" alt="Anicat Logo" className="h-16 w-auto object-contain" />
            </div>
            <div className="space-y-2">
              <h2 className="text-2xl font-semibold tracking-tight text-foreground flex items-center justify-center gap-2">
                <span>Welcome to Anicat</span>
                <Sparkles className="text-accent " size={20} />
              </h2>
              <p className="text-sm text-muted-foreground leading-relaxed px-4">
                Stream anime, read manga, and track your library automatically in a premium desktop interface.
              </p>
            </div>

            <div className="space-y-3.5 text-left max-w-sm mx-auto bg-foreground/[0.02] border border-border p-5 rounded-lg">
              <div className="flex items-center space-x-3 text-xs text-foreground/80 font-semibold">
                <Globe size={18} className="text-accent shrink-0" />
                <span>Syncs instantly with AniList (Anime & Manga)</span>
              </div>
              <div className="flex items-center space-x-3 text-xs text-foreground/80 font-semibold">
                <Monitor size={18} className="text-accent shrink-0" />
                <span>Media player & built-in manga reader</span>
              </div>
              <div className="flex items-center space-x-3 text-xs text-foreground/80 font-semibold">
                <Sparkles size={18} className="text-accent shrink-0" />
                <span>High-performance GPU upscaling (Anime4K)</span>
              </div>
              <div className="flex items-center space-x-3 text-xs text-foreground/80 font-semibold">
                <Download size={18} className="text-accent shrink-0" />
                <span>Offline download manager</span>
              </div>
            </div>

            <button
              onClick={() => setStep(2)}
              className="w-full flex items-center justify-center space-x-2 py-3.5 bg-accent hover:bg-accent-light text-black rounded-lg font-bold  transition-all cursor-pointer"
            >
              <span>Get Started</span>
              <ArrowRight size={16} />
            </button>
          </div>
        )}

        {/* Step 2: Connect AniList */}
        {step === 2 && (
          <div className="space-y-6 animate-fade-in">
            <div className="space-y-2 text-center">
              <h2 className="text-xl font-semibold text-foreground">Connect AniList</h2>
              <p className="text-xs text-muted-foreground px-6 leading-relaxed">
                Connect your account to access your custom watch lists, track anime/manga progress, and sync your rating history.
              </p>
            </div>

            <div className="space-y-4">
              <button
                onClick={() => {
                  setAuthPending(true);
                  invoke("start_anilist_auth")
                    .then(() => setAuthPending(false))
                    .catch(() => setAuthPending(false));
                }}
                className="w-full flex items-center justify-center space-x-2 py-3.5 bg-foreground/[0.04] hover:bg-foreground/[0.08] border border-border text-foreground rounded-lg font-bold transition-all cursor-pointer"
              >
                {authPending ? (
                  <>
                    <Loader2 size={16} className="animate-spin text-accent" />
                    <span>Auth Window Opened...</span>
                  </>
                ) : (
                  <>
                    <Globe size={16} className="text-accent" />
                    <span>Authorize with AniList</span>
                  </>
                )}
              </button>

              <div className="space-y-2">
                <label className="meta-mono text-muted-foreground/70">Paste Authorization URL or Token</label>
                <input
                  type="password"
                  value={tokenInput}
                  onChange={(e) => handleTokenChange(e.target.value)}
                  placeholder="Paste here to link account..."
                  className="w-full bg-foreground/[0.02] border border-border rounded-lg p-3.5 text-sm font-medium focus:border-accent/40 outline-none transition-all placeholder:text-muted-foreground/40 text-foreground"
                />
              </div>

              {/* Status Message */}
              {validating && (
                <div className="flex items-center justify-center space-x-2 text-xs text-muted-foreground bg-foreground/[0.01] py-2 rounded-lg">
                  <Loader2 size={14} className="animate-spin text-accent" />
                  <span>Checking authentication...</span>
                </div>
              )}

              {connectedUser && (
                <div className="flex items-center space-x-2.5 p-3 rounded-lg bg-green-500/10 border border-green-500/25 text-green-400 text-xs font-semibold animate-scale-in">
                  <CheckCircle2 size={16} />
                  <span>Connected successfully as <strong className="text-foreground">{connectedUser}</strong>!</span>
                </div>
              )}

              {authError && (
                <div className="flex items-start space-x-2.5 p-3 rounded-lg bg-red-500/10 border border-red-500/25 text-red-400 text-xs leading-relaxed animate-scale-in">
                  <ShieldAlert size={16} className="shrink-0 mt-0.5" />
                  <span>{authError}</span>
                </div>
              )}
            </div>

            <div className="flex justify-between items-center pt-2">
              <button onClick={() => setStep(1)} className="text-xs font-bold text-muted-foreground/70 hover:text-foreground transition-colors cursor-pointer">
                Back
              </button>
              <button onClick={() => setStep(3)} className="text-xs font-bold text-accent hover:text-accent-light transition-colors cursor-pointer">
                Skip for now
              </button>
            </div>
          </div>
        )}

        {/* Step 3: Preferences */}
        {step === 3 && (
          <div className="space-y-6 animate-fade-in">
            <div className="space-y-2 text-center">
              <h2 className="text-xl font-semibold text-foreground">Choose Preferences</h2>
              <p className="text-xs text-muted-foreground leading-relaxed">
                Personalize your experience. These settings can always be updated later.
              </p>
            </div>

            <div className="space-y-5">
              {/* Theme preference */}
              <div className="space-y-2.5">
                <label className="meta-mono text-muted-foreground/70 flex items-center gap-1.5">
                  <Palette size={12} className="text-accent" />
                  <span>Interface Theme</span>
                </label>
                <div className="grid grid-cols-3 gap-3">
                  {(["system", "dark", "light"] as const).map((t) => (
                    <button
                      key={t}
                      onClick={() => handleThemeChange(t)}
                      className={`py-3 rounded-lg font-bold text-xs uppercase tracking-wider transition-all cursor-pointer ${
                        theme === t
                          ? "bg-accent text-black "
                          : "bg-foreground/[0.03] border border-border text-muted-foreground hover:text-foreground"
                      }`}
                    >
                      {t}
                    </button>
                  ))}
                </div>
              </div>

              {/* Visual Skin Preference */}
              <div className="space-y-2.5">
                <label className="meta-mono text-muted-foreground/70 flex items-center gap-1.5">
                  <Palette size={12} className="text-accent" />
                  <span>Visual Theme Skin</span>
                </label>
                <div className="grid grid-cols-3 gap-3">
                  {([
                    { key: "neon-abyss" as const, label: "Ink & Index" },
                    { key: "sakura-zen" as const, label: "Sakura Zen" },
                    { key: "retro-manga" as const, label: "Retro Manga" }
                  ]).map((t) => (
                    <button
                      key={t.key}
                      onClick={() => handleUiStyleChange(t.key)}
                      className={`py-3 rounded-lg font-bold text-xs uppercase tracking-wider transition-all cursor-pointer ${
                        uiStyle === t.key
                          ? "bg-accent text-black "
                          : "bg-foreground/[0.03] border border-border text-muted-foreground hover:text-foreground"
                      }`}
                    >
                      {t.label}
                    </button>
                  ))}
                </div>
              </div>

              {/* Time Format */}
              <div className="space-y-2.5">
                <label className="meta-mono text-muted-foreground/70 flex items-center gap-1.5">
                  <Clock size={12} className="text-accent" />
                  <span>Time Format (for Airing Schedules)</span>
                </label>
                <div className="grid grid-cols-2 gap-3">
                  {(["24h", "12h"] as const).map((f) => (
                    <button
                      key={f}
                      onClick={() => handleTimeFormatChange(f)}
                      className={`py-3 rounded-lg font-bold text-xs transition-all cursor-pointer ${
                        timeFormat === f
                          ? "bg-accent text-black "
                          : "bg-foreground/[0.03] border border-border text-muted-foreground hover:text-foreground"
                      }`}
                    >
                      {f === "24h" ? "24-Hour (13:00)" : "12-Hour (1:00 PM)"}
                    </button>
                  ))}
                </div>
              </div>

              {/* Preferred Translation (Sub/Dub) */}
              <div className="space-y-2.5">
                <label className="meta-mono text-muted-foreground/70 flex items-center gap-1.5">
                  <Globe size={12} className="text-accent" />
                  <span>Preferred Translation</span>
                </label>
                <div className="grid grid-cols-2 gap-3">
                  {(["sub", "dub"] as const).map((t) => (
                    <button
                      key={t}
                      onClick={() => handleTranslationTypeChange(t)}
                      className={`py-3 rounded-lg font-bold text-xs transition-all cursor-pointer ${
                        translationType === t
                          ? "bg-accent text-black "
                          : "bg-foreground/[0.03] border border-border text-muted-foreground hover:text-foreground"
                      }`}
                    >
                      {t === "sub" ? "Subtitled (Sub)" : "English Dubbed (Dub)"}
                    </button>
                  ))}
                </div>
              </div>

              {/* GPU Upscaling */}
              <div className="space-y-2.5">
                <label className="meta-mono text-muted-foreground/70 flex items-center gap-1.5">
                  <Monitor size={12} className="text-accent" />
                  <span>Anime4K GPU Upscaling</span>
                </label>
                <div className="grid grid-cols-2 gap-3">
                  {(["on", "off"] as const).map((g) => (
                    <button
                      key={g}
                      onClick={() => handleGpuUpscalingChange(g)}
                      className={`py-3 rounded-lg font-bold text-xs transition-all cursor-pointer ${
                        gpuUpscaling === g
                          ? "bg-accent text-black "
                          : "bg-foreground/[0.03] border border-border text-muted-foreground hover:text-foreground"
                      }`}
                    >
                      {g === "on" ? "On (Recommended)" : "Off"}
                    </button>
                  ))}
                </div>
              </div>

              {/* Smooth Motion (Frame Interpolation) */}
              <div className="space-y-2.5">
                <label className="meta-mono text-muted-foreground/70 flex items-center gap-1.5">
                  <Gauge size={12} className="text-accent" />
                  <span>Smooth Motion</span>
                </label>
                <p className="text-[11px] text-muted-foreground/70 leading-relaxed">
                  Frame interpolation for smoother panning, up to your display's refresh rate. Best left off for on-twos anime — may look soap-opera-y.
                </p>
                <div className="grid grid-cols-2 gap-3">
                  {(["off", "on"] as const).map((g) => (
                    <button
                      key={g}
                      onClick={() => handleInterpolationChange(g)}
                      className={`py-3 rounded-lg font-bold text-xs transition-all cursor-pointer ${
                        interpolation === g
                          ? "bg-accent text-black "
                          : "bg-foreground/[0.03] border border-border text-muted-foreground hover:text-foreground"
                      }`}
                    >
                      {g === "off" ? "Off (Recommended)" : "On"}
                    </button>
                  ))}
                </div>
              </div>
            </div>

            <div className="pt-4 border-t border-border space-y-3">
              <div className="text-center text-xs text-muted-foreground font-semibold">Would you like to see key player controls (like upscaling) and shortcuts?</div>
              <div className="flex gap-3">
                <button
                  onClick={() => setStep(4)}
                  className="flex-1 py-3 bg-accent hover:bg-accent-light text-black rounded-lg font-bold  transition-all cursor-pointer text-xs"
                >
                  Yes, show shortcuts
                </button>
                <button
                  onClick={handleFinish}
                  className="flex-1 py-3 bg-foreground/[0.04] hover:bg-foreground/[0.08] border border-border text-foreground rounded-lg font-bold transition-all cursor-pointer text-xs"
                >
                  No, skip to app
                </button>
              </div>
            </div>
          </div>
        )}

        {/* Step 4: Shortcuts & Info */}
        {step === 4 && (
          <div className="space-y-6 animate-fade-in max-h-[480px] overflow-y-auto pr-2">
            <div className="space-y-2 text-center">
              <h2 className="text-xl font-semibold text-foreground">Shortcuts & Info</h2>
              <p className="text-xs text-muted-foreground leading-relaxed">
                Key features and player keyboard shortcuts.
              </p>
            </div>

            <div className="space-y-4 text-xs">
              <div className="space-y-2">
                <h3 className="font-bold text-accent uppercase tracking-wider text-[10px]">1. Settings — Ctrl + number</h3>
                <p className="text-muted-foreground leading-relaxed">Toggle these live in the external MPV window during playback — they're saved back into your app settings too:</p>
                <div className="grid grid-cols-2 gap-2 bg-foreground/[0.02] border border-border p-3 rounded-lg">
                  <div className="flex justify-between py-1 border-b border-border"><span className="text-muted-foreground">Toggle Upscaling</span><kbd className="px-1.5 py-0.5 bg-foreground/[0.08] border border-border rounded text-[10px] text-foreground font-mono">Ctrl + 1</kbd></div>
                  <div className="flex justify-between py-1 border-b border-border"><span className="text-muted-foreground">Toggle Auto-skip Intro</span><kbd className="px-1.5 py-0.5 bg-foreground/[0.08] border border-border rounded text-[10px] text-foreground font-mono">Ctrl + 2</kbd></div>
                  <div className="flex justify-between py-1 border-b border-border"><span className="text-muted-foreground">Toggle Smooth Motion</span><kbd className="px-1.5 py-0.5 bg-foreground/[0.08] border border-border rounded text-[10px] text-foreground font-mono">Ctrl + 3</kbd></div>
                  <div className="flex justify-between py-1 border-b border-border"><span className="text-muted-foreground">Toggle Autoplay Next</span><kbd className="px-1.5 py-0.5 bg-foreground/[0.08] border border-border rounded text-[10px] text-foreground font-mono">Ctrl + 4</kbd></div>
                </div>
              </div>

              <div className="space-y-2">
                <h3 className="font-bold text-accent uppercase tracking-wider text-[10px]">2. Actions — Shift + letter</h3>
                <p className="text-muted-foreground leading-relaxed">One-off playback actions, same MPV window:</p>
                <div className="grid grid-cols-2 gap-2 bg-foreground/[0.02] border border-border p-3 rounded-lg">
                  <div className="flex justify-between py-1 border-b border-border"><span className="text-muted-foreground">Reload Episode</span><kbd className="px-1.5 py-0.5 bg-foreground/[0.08] border border-border rounded text-[10px] text-foreground font-mono">Shift + R</kbd></div>
                  <div className="flex justify-between py-1 border-b border-border"><span className="text-muted-foreground">Skip Segment</span><kbd className="px-1.5 py-0.5 bg-foreground/[0.08] border border-border rounded text-[10px] text-foreground font-mono">Shift + S</kbd></div>
                  <div className="flex justify-between py-1 border-b border-border"><span className="text-muted-foreground">Toggle Sub/Dub</span><kbd className="px-1.5 py-0.5 bg-foreground/[0.08] border border-border rounded text-[10px] text-foreground font-mono">Shift + T</kbd></div>
                  <div className="flex justify-between py-1 border-b border-border"><span className="text-muted-foreground">Nudge Skip Timing</span><kbd className="px-1.5 py-0.5 bg-foreground/[0.08] border border-border rounded text-[10px] text-foreground font-mono">[ / ]</kbd></div>
                </div>
              </div>

              <div className="space-y-2">
                <h3 className="font-bold text-accent uppercase tracking-wider text-[10px]">3. Manga Reading & Tracking</h3>
                <p className="text-muted-foreground leading-relaxed">Read manga chapters with our built-in reader. Your reading progress is automatically tracked and synchronized to AniList, ensuring your library is always up to date.</p>
              </div>
            </div>

            <div className="pt-2">
              <button
                onClick={handleFinish}
                className="w-full py-3.5 bg-accent hover:bg-accent-light text-black rounded-lg font-bold  transition-all cursor-pointer"
              >
                Let's Go!
              </button>
            </div>
          </div>
        )}

      </div>
    </div>
  );
}
