import { useState, useEffect, useRef } from "react";
import { invoke } from "@/lib/transport";
import { Loader2, Check } from "lucide-react";
import { mediaApi, dispatchRefresh } from "@/lib/api";
import { useAppStore } from "@/stores/app";
import { usesOverlayTitlebar } from "@/lib/platform";

interface OnboardingProps {
  onComplete: () => void;
}

type Step = 1 | 2 | 3 | 4;
type AccountState = "idle" | "waiting" | "connected" | "error";

const LAST_STEP: Step = 4;

const STEPS: { n: Step; label: string }[] = [
  { n: 1, label: "Welcome" },
  { n: 2, label: "AniList" },
  { n: 3, label: "Playback" },
  { n: 4, label: "Shortcuts" }
];

const SELECT_CLASS =
  "min-w-[170px] bg-card border border-border rounded-lg px-3 py-1.5 text-[13px] font-medium text-foreground outline-none focus:border-accent/40 cursor-pointer";

const CARD_CLASS = "bg-card border border-border rounded-xl overflow-hidden";
const CARD_HEADER_CLASS = "px-5 py-3.5 border-b border-border bg-foreground/[0.02]";
const ROW_CLASS = "flex items-center gap-4 py-3 border-b border-border last:border-b-0";

export function Onboarding({ onComplete }: OnboardingProps) {
  const [step, setStep] = useState<Step>(1);
  const [seen, setSeen] = useState<Record<number, boolean>>({ 1: true });
  // Move focus into the panel on mount so keyboard users start inside the
  // dialog rather than on the app behind it.
  const panelRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    panelRef.current?.focus();
  }, []);
  const [tokenInput, setTokenInput] = useState("");
  const [validating, setValidating] = useState(false);
  const [connectedUser, setConnectedUser] = useState<string | null>(null);
  const [authError, setAuthError] = useState<string | null>(null);
  const [authOpened, setAuthOpened] = useState(false);
  const [theme, setTheme] = useState<"system" | "dark" | "light">("system");
  const [uiStyle, setUiStyle] = useState<"ink-and-index" | "sakura-zen" | "retro-manga">("ink-and-index");
  const [timeFormat, setTimeFormat] = useState<"12h" | "24h">("24h");
  const [gpuUpscaling, setGpuUpscaling] = useState<"on" | "off">("on");
  const [translationType, setTranslationType] = useState<"sub" | "dub">("sub");
  const cinemaEnabled = useAppStore((s) => s.cinemaEnabled);
  const setCinemaEnabled = useAppStore((s) => s.setCinemaEnabled);

  const account: AccountState = connectedUser
    ? "connected"
    : authError
      ? "error"
      : authOpened
        ? "waiting"
        : "idle";

  useEffect(() => {
    const savedStyle = (localStorage.getItem("anicat_ui_style") as "ink-and-index" | "sakura-zen" | "retro-manga" | null) || "ink-and-index";
    setUiStyle(savedStyle);
    const savedTheme = localStorage.getItem("anicat_theme") as "system" | "dark" | "light" | null;
    if (savedTheme) {
      setTheme(savedTheme);
    }
  }, []);

  useEffect(() => {
    mediaApi.getConfig().then((cfg) => {
      if (cfg?.stream?.shader_profile === "on" || cfg?.stream?.shader_profile === "off") {
        setGpuUpscaling(cfg.stream.shader_profile);
      }
      if (cfg?.general?.time_format === "12h" || cfg?.general?.time_format === "24h") {
        setTimeFormat(cfg.general.time_format);
      }
      if (cfg?.stream?.translation_type === "sub" || cfg?.stream?.translation_type === "dub") {
        setTranslationType(cfg.stream.translation_type);
      }
    }).catch(() => {});
  }, []);

  const go = (n: Step) => {
    setStep(n);
    setSeen((s) => ({ ...s, [n]: true }));
  };

  const handleGpuUpscalingChange = async (val: "on" | "off") => {
    setGpuUpscaling(val);
    try {
      await mediaApi.updateConfig({ stream: { shader_profile: val } });
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
        } else {
          setAuthError(healthData.auth_error || "Invalid token or authorization rejected.");
        }
      } catch (err) {
        setAuthError("Couldn't validate token. Check network settings.");
      } finally {
        setValidating(false);
      }
    }
  };

  const startAuth = () => {
    setAuthError(null);
    setAuthOpened(true);
    invoke("start_anilist_auth").catch(() => {});
  };

  const disconnect = async () => {
    setConnectedUser(null);
    setAuthError(null);
    setAuthOpened(false);
    setTokenInput("");
    try {
      await mediaApi.updateConfig({ api: { anilist_token: "" } });
    } catch {}
    window.dispatchEvent(new Event("anicat_health_recheck"));
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

  const handleUiStyleChange = (style: "ink-and-index" | "sakura-zen" | "retro-manga") => {
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

  const statusLabel =
    account === "connected" ? "Connected" : account === "error" ? "Failed" : account === "waiting" ? "Awaiting paste" : "Not connected";
  const statusColor =
    account === "connected" ? "text-success" : account === "error" ? "text-danger" : "text-muted-foreground/70";

  // Skip is a per-step shortcut, not a single action: on the first screen it
  // means "don't set anything up", later it just means "leave this one alone".
  const skipLabel =
    step === 1 ? "Skip setup" : step === 2 ? (account === "connected" ? "" : "Skip, connect later") : step === 3 ? "Use defaults" : "";
  const onSkip = () => (step === 1 ? handleFinish() : go(Math.min(LAST_STEP, (step + 1)) as Step));

  const styleCards = [
    {
      key: "ink-and-index" as const,
      name: "Ink & Index",
      sub: "Warm ink / Indigo accent",
      swatch: "linear-gradient(135deg, #161310 0%, #1e1a15 60%, #252015 100%)",
      chips: (
        <>
          <div className="flex-1 h-[30px] rounded-[10px]" style={{ background: "#1e1a15", border: "1px solid rgba(255,255,255,0.05)" }} />
          <div className="flex-1 h-[30px] rounded-[10px]" style={{ background: "rgba(143,184,220,0.3)", border: "1px solid rgba(143,184,220,0.4)" }} />
        </>
      )
    },
    {
      key: "sakura-zen" as const,
      name: "Sakura Zen",
      sub: "Soft pastel / Japanese editorial",
      swatch: "linear-gradient(135deg, #130910 0%, #1a0e14 60%, #1f1018 100%)",
      chips: (
        <>
          <div className="flex-1 h-[30px] rounded-[10px]" style={{ background: "rgba(244,180,196,0.08)", border: "1px solid rgba(232,160,180,0.2)" }} />
          <div className="flex-1 h-[30px] rounded-[10px]" style={{ background: "rgba(232,160,180,0.25)", border: "1px solid rgba(232,160,180,0.4)" }} />
        </>
      )
    },
    {
      key: "retro-manga" as const,
      name: "Retro Manga",
      sub: "Halftone dot / Manga panel style",
      swatch: "linear-gradient(135deg, #191410 0%, #241e17 100%)",
      chips: (
        <>
          <div className="flex-1 h-[30px] rounded-md" style={{ background: "#ede8e0", border: "3px solid #0c0a08" }} />
          <div className="flex-1 h-[30px] rounded-md" style={{ background: "#c02024", border: "2px solid #0c0a08" }} />
        </>
      )
    }
  ];

  return (
    <div className="fixed inset-0 z-[999] bg-background animate-fade-in">
      {/* This blocks the whole app on first run, so it has to say so: without
          dialog semantics the sidebar behind it stayed in the tab order and
          focus never entered the panel. */}
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-label="Welcome to Anicat, setup"
        tabIndex={-1}
        className="h-full flex outline-none text-foreground"
      >
        {/* Step rail */}
        <aside className="w-[200px] shrink-0 bg-card border-r border-border flex flex-col">
          {usesOverlayTitlebar && <div data-tauri-drag-region className="h-10 shrink-0" />}
          <nav className="flex-1" aria-label="Setup steps">
            <div className="meta-mono text-muted-foreground/70 px-5 pt-4 pb-1.5">Setup</div>
            {STEPS.map(({ n, label }) => {
              const active = step === n;
              return (
                <button
                  key={n}
                  onClick={() => go(n)}
                  aria-current={active ? "step" : undefined}
                  className={`w-full flex items-center justify-between pl-5 pr-4 py-[7px] text-[13px] text-left cursor-pointer transition-colors ${
                    active
                      ? "bg-accent/10 shadow-[inset_2px_0_0_var(--accent-color)] text-foreground font-semibold"
                      : "text-foreground/70 hover:text-foreground font-normal"
                  }`}
                >
                  <span>{label}</span>
                  <span className={`meta-mono ${!active && seen[n] ? "text-accent" : "text-muted-foreground/70"}`}>
                    {!active && seen[n] ? (
                      <>
                        <Check size={12} aria-hidden="true" />
                        <span className="sr-only">visited</span>
                      </>
                    ) : (
                      n
                    )}
                  </span>
                </button>
              );
            })}
          </nav>
          <div className="px-4 pb-4 flex flex-col gap-2.5">
            <div className="flex justify-center pb-1 opacity-10 pointer-events-none">
              <img src="/anicat_logo.png" alt="" className="h-20 object-contain grayscale" />
            </div>
            <div className="meta-mono text-muted-foreground/70 text-center">Step {step} of {LAST_STEP}</div>
          </div>
        </aside>

        {/* Content column */}
        <div className="flex-1 min-w-0 flex flex-col">
          {usesOverlayTitlebar && <div data-tauri-drag-region className="h-10 shrink-0" />}
          <div className="flex-1 overflow-y-auto px-10 pt-2">
            <div className="max-w-[640px]">

              {/* Step 1: Welcome */}
              {step === 1 && (
                <div className="animate-fade-in flex flex-col gap-6">
                  <div>
                    <h1 className="text-[22px] leading-[30px] font-semibold tracking-tight">Set up Anicat</h1>
                    <p className="mt-0.5 text-[13px] text-muted-foreground">
                      Four short screens. Nothing here is permanent, it all lives in Settings afterwards.
                    </p>
                  </div>
                  <section className={CARD_CLASS}>
                    <div className={CARD_HEADER_CLASS}>
                      <h2 className="text-[13px] font-semibold">What setup covers</h2>
                    </div>
                    <div className="px-5 py-1">
                      {[
                        {
                          step: "Step 2",
                          title: "Connect AniList",
                          body: "Pulls in your lists and keeps progress and scores in sync. Optional, playback and the episode list work without it."
                        },
                        {
                          step: "Step 3",
                          title: "Playback and appearance",
                          body: "Subs or dubs, Anime4K upscaling, theme and skin."
                        },
                        {
                          step: "Step 4",
                          title: "Shortcuts",
                          body: "The player keys worth knowing, plus how manga reading tracks back to AniList."
                        }
                      ].map((row) => (
                        <div key={row.step} className="flex gap-4 py-3.5 border-b border-border last:border-b-0">
                          <div className="meta-mono text-muted-foreground/70 w-[72px] shrink-0 pt-px">{row.step}</div>
                          <div>
                            <div className="text-[13px] font-medium">{row.title}</div>
                            <div className="text-xs text-muted-foreground leading-relaxed mt-0.5">{row.body}</div>
                          </div>
                        </div>
                      ))}
                    </div>
                  </section>

                  <section className={CARD_CLASS}>
                    <div className={`${CARD_HEADER_CLASS} flex items-center justify-between gap-4`}>
                      <div>
                        <h2 className="text-[13px] font-semibold">Movies and series</h2>
                        <p className="mt-0.5 text-xs text-muted-foreground leading-relaxed">
                          A second mode, switched with the sidebar logo. Needs a free TMDB token, added later in
                          Settings — this only turns the switch on.
                        </p>
                      </div>
                      <button
                        role="switch"
                        aria-checked={cinemaEnabled}
                        aria-label="Movies and series"
                        onClick={() => setCinemaEnabled(!cinemaEnabled)}
                        className={`relative h-[22px] w-[38px] shrink-0 rounded-full border-none cursor-pointer transition-colors ${
                          cinemaEnabled ? "bg-accent" : "bg-foreground/20"
                        }`}
                      >
                        <span
                          className="absolute top-0.5 h-[18px] w-[18px] rounded-full bg-foreground transition-all"
                          style={{ left: cinemaEnabled ? "18px" : "2px" }}
                        />
                      </button>
                    </div>
                  </section>
                </div>
              )}

              {/* Step 2: Connect AniList */}
              {step === 2 && (
                <div className="animate-fade-in flex flex-col gap-6">
                  <div>
                    <h1 className="text-[22px] leading-[30px] font-semibold tracking-tight">Connect AniList</h1>
                    <p className="mt-0.5 text-[13px] text-muted-foreground">
                      Used for tracking only. Watching and reading work either way.
                    </p>
                  </div>

                  <section className={CARD_CLASS}>
                    <div className={`${CARD_HEADER_CLASS} flex items-center justify-between gap-4`}>
                      <div>
                        <h2 className="text-[13px] font-semibold">Account</h2>
                        <p className="mt-0.5 text-xs text-muted-foreground leading-relaxed">
                          Anicat opens AniList in your browser. Approve access, then copy the URL you land on back into the field below.
                        </p>
                      </div>
                      <div className={`meta-mono whitespace-nowrap ${statusColor}`}>{statusLabel}</div>
                    </div>

                    <div className="px-5 pt-1 pb-4">
                      {account === "idle" && (
                        <div className={ROW_CLASS}>
                          <div className="flex-1">
                            <div className="text-[13px] font-medium">Authorize</div>
                            <div className="text-xs text-muted-foreground mt-0.5 leading-relaxed">
                              Sign in and approve access. Progress, scores and list status sync both ways afterwards.
                            </div>
                          </div>
                          <button
                            onClick={startAuth}
                            className="bg-accent hover:bg-accent-light text-black border-none rounded-[10px] px-[18px] py-2.5 text-[13px] font-semibold cursor-pointer whitespace-nowrap transition-colors"
                          >
                            Open AniList
                          </button>
                        </div>
                      )}

                      {account === "waiting" && (
                        <div className={ROW_CLASS}>
                          <div className="flex-1">
                            <div className="text-[13px] font-medium">Waiting for your browser</div>
                            <div className="text-xs text-muted-foreground mt-0.5 leading-relaxed">
                              Approve access in the tab that just opened, then paste the redirect URL below.
                            </div>
                          </div>
                          <button
                            onClick={startAuth}
                            className="bg-foreground/[0.04] hover:bg-foreground/[0.08] border border-border text-foreground rounded-[10px] px-[18px] py-2.5 text-[13px] font-semibold cursor-pointer whitespace-nowrap transition-colors"
                          >
                            Reopen
                          </button>
                        </div>
                      )}

                      {account === "connected" && (
                        <div className={`${ROW_CLASS} animate-scale-in`}>
                          <div className="flex-1">
                            <div className="text-[13px] font-medium">
                              Signed in as <span className="text-success">{connectedUser}</span>
                            </div>
                            <div className="text-xs text-muted-foreground mt-0.5 leading-relaxed">
                              Your lists are loading in the background. Nothing else to do here.
                            </div>
                          </div>
                          <button
                            onClick={disconnect}
                            className="bg-transparent border border-border text-muted-foreground hover:text-foreground rounded-[10px] px-3.5 py-2 text-xs cursor-pointer whitespace-nowrap transition-colors"
                          >
                            Use another account
                          </button>
                        </div>
                      )}

                      {account === "error" && (
                        <div className="animate-scale-in my-3.5 px-3.5 py-3 rounded-[10px] bg-danger/10 border border-danger/25 flex gap-3 items-start">
                          <div className="flex-1">
                            <div className="text-xs font-semibold text-danger-light">Authorization was rejected</div>
                            <div className="text-xs text-muted-foreground mt-1 leading-relaxed">{authError}</div>
                          </div>
                          <button
                            onClick={startAuth}
                            className="bg-foreground/[0.04] hover:bg-foreground/[0.08] border border-border text-foreground rounded-[10px] px-3.5 py-1.5 text-xs font-semibold cursor-pointer whitespace-nowrap transition-colors"
                          >
                            Try again
                          </button>
                        </div>
                      )}

                      {account !== "connected" && (
                        <div className="pt-3 flex flex-col gap-2">
                          <label htmlFor="anilist-token" className="text-xs text-muted-foreground leading-relaxed">
                            Paste the redirect URL (or the token itself)
                          </label>
                          <input
                            id="anilist-token"
                            type="password"
                            value={tokenInput}
                            onChange={(e) => handleTokenChange(e.target.value)}
                            placeholder="https://anilist.co/api/v2/oauth/..."
                            className="w-full box-border bg-card border border-border rounded-[10px] px-3 py-2.5 text-[13px] text-foreground outline-none focus:border-accent/40 placeholder:text-muted-foreground/40"
                          />
                          {validating && (
                            <div className="flex items-center gap-2 text-xs text-muted-foreground">
                              <Loader2 size={14} className="animate-spin text-accent" />
                              <span>Checking authentication...</span>
                            </div>
                          )}
                        </div>
                      )}
                    </div>
                  </section>
                </div>
              )}

              {/* Step 3: Playback and appearance */}
              {step === 3 && (
                <div className="animate-fade-in flex flex-col gap-6">
                  <div>
                    <h1 className="text-[22px] leading-[30px] font-semibold tracking-tight">Playback and appearance</h1>
                    <p className="mt-0.5 text-[13px] text-muted-foreground">The handful of settings people change on day one.</p>
                  </div>

                  <section className={CARD_CLASS}>
                    <div className={CARD_HEADER_CLASS}>
                      <h2 className="text-[13px] font-semibold">Playback</h2>
                    </div>
                    <div className="px-5 pt-1 pb-3">
                      <div className={ROW_CLASS}>
                        <div className="flex-1">
                          <label htmlFor="pref-translation" className="text-[13px] font-medium">Preferred translation</label>
                          <p className="mt-0.5 text-xs text-muted-foreground">Which release Anicat reaches for first.</p>
                        </div>
                        <select
                          id="pref-translation"
                          value={translationType}
                          onChange={(e) => handleTranslationTypeChange(e.target.value as "sub" | "dub")}
                          className={SELECT_CLASS}
                        >
                          <option value="sub">Subtitled</option>
                          <option value="dub">Dubbed</option>
                        </select>
                      </div>

                      <div className={ROW_CLASS}>
                        <div className="flex-1">
                          <span className="text-[13px] font-medium">Anime4K upscaling</span>
                          <p className="mt-0.5 text-xs text-muted-foreground leading-relaxed">
                            Sharper picture, more GPU load.{" "}
                            <kbd className="px-1.5 py-px bg-foreground/[0.08] border border-border rounded text-[11px] font-mono">Ctrl 1</kbd>{" "}
                            flips it mid-episode if it struggles.
                          </p>
                        </div>
                        <button
                          role="switch"
                          aria-checked={gpuUpscaling === "on"}
                          aria-label="Anime4K upscaling"
                          onClick={() => handleGpuUpscalingChange(gpuUpscaling === "on" ? "off" : "on")}
                          className={`relative h-[22px] w-[38px] shrink-0 rounded-full border-none cursor-pointer transition-colors ${
                            gpuUpscaling === "on" ? "bg-accent" : "bg-foreground/20"
                          }`}
                        >
                          <span
                            className="absolute top-0.5 h-[18px] w-[18px] rounded-full bg-foreground transition-all"
                            style={{ left: gpuUpscaling === "on" ? "18px" : "2px" }}
                          />
                        </button>
                      </div>

                      <div className={ROW_CLASS}>
                        <div className="flex-1">
                          <label htmlFor="pref-time" className="text-[13px] font-medium">Time format</label>
                          <p className="mt-0.5 text-xs text-muted-foreground">Used by the airing schedule.</p>
                        </div>
                        <select
                          id="pref-time"
                          value={timeFormat}
                          onChange={(e) => handleTimeFormatChange(e.target.value as "12h" | "24h")}
                          className={SELECT_CLASS}
                        >
                          <option value="24h">24-hour</option>
                          <option value="12h">12-hour (AM/PM)</option>
                        </select>
                      </div>
                    </div>
                  </section>

                  <section className={`${CARD_CLASS} mb-2`}>
                    <div className={CARD_HEADER_CLASS}>
                      <h2 className="text-[13px] font-semibold">Appearance</h2>
                      <p className="mt-0.5 text-xs text-muted-foreground">Theme follows your system unless you pin it.</p>
                    </div>
                    <div className="px-5 pt-1 pb-4">
                      <div className={ROW_CLASS}>
                        <div className="flex-1">
                          <label htmlFor="pref-theme" className="text-[13px] font-medium">Theme</label>
                        </div>
                        <select
                          id="pref-theme"
                          value={theme}
                          onChange={(e) => handleThemeChange(e.target.value as "system" | "dark" | "light")}
                          className={SELECT_CLASS}
                        >
                          <option value="system">System Default</option>
                          <option value="dark">Dark</option>
                          <option value="light">Light</option>
                        </select>
                      </div>

                      <div className="pt-3 flex flex-col gap-3">
                        <span className="text-[13px] font-medium">Style</span>
                        <div className="grid grid-cols-3 gap-3">
                          {styleCards.map((card) => (
                            <button
                              key={card.key}
                              onClick={() => handleUiStyleChange(card.key)}
                              aria-pressed={uiStyle === card.key}
                              className={`rounded-xl overflow-hidden text-left cursor-pointer p-0 bg-transparent border-2 transition-colors ${
                                uiStyle === card.key ? "border-accent" : "border-border"
                              }`}
                            >
                              <div className="h-[76px] w-full" style={{ background: card.swatch }}>
                                <div className="flex gap-1.5 p-2.5 h-full box-border items-end">{card.chips}</div>
                              </div>
                              <div className="px-3 py-2 bg-card">
                                <div className="text-xs font-bold">{card.name}</div>
                                <div className="text-[10px] text-muted-foreground mt-0.5">{card.sub}</div>
                              </div>
                            </button>
                          ))}
                        </div>
                      </div>
                    </div>
                  </section>
                </div>
              )}

              {/* Step 4: Shortcuts */}
              {step === 4 && (
                <div className="animate-fade-in flex flex-col gap-6">
                  <div>
                    <h1 className="text-[22px] leading-[30px] font-semibold tracking-tight">Shortcuts</h1>
                    <p className="mt-0.5 text-[13px] text-muted-foreground leading-relaxed">
                      These work in the mpv window while an episode plays.
                    </p>
                  </div>

                  <section className={CARD_CLASS}>
                    <div className={CARD_HEADER_CLASS}>
                      <h2 className="text-[13px] font-semibold">Toggles, Ctrl + number</h2>
                      <p className="mt-0.5 text-xs text-muted-foreground">Flipping one saves it back into Settings.</p>
                    </div>
                    <div className="px-5 pt-1 pb-3">
                      {[
                        ["Upscaling", "Ctrl 1"],
                        ["Auto-skip intro", "Ctrl 2"],
                        ["Autoplay next", "Ctrl 4"]
                      ].map(([label, key]) => (
                        <div key={key} className="flex justify-between items-center py-2.5 border-b border-border last:border-b-0">
                          <span className="text-[13px]">{label}</span>
                          <kbd className="px-1.5 py-0.5 bg-foreground/[0.08] border border-border rounded-md text-[11px] font-mono">{key}</kbd>
                        </div>
                      ))}
                    </div>
                  </section>

                  <section className={CARD_CLASS}>
                    <div className={CARD_HEADER_CLASS}>
                      <h2 className="text-[13px] font-semibold">Actions, Shift + letter</h2>
                    </div>
                    <div className="px-5 pt-1 pb-3">
                      {[
                        ["Reload episode", "Shift R"],
                        ["Skip segment", "Shift S"],
                        ["Sub / dub", "Shift T"],
                        ["Rotate video", "Shift V"]
                      ].map(([label, key]) => (
                        <div key={key} className="flex justify-between items-center py-2.5 border-b border-border last:border-b-0">
                          <span className="text-[13px]">{label}</span>
                          <kbd className="px-1.5 py-0.5 bg-foreground/[0.08] border border-border rounded-md text-[11px] font-mono">{key}</kbd>
                        </div>
                      ))}
                    </div>
                  </section>

                  <section className={`${CARD_CLASS} mb-2`}>
                    <div className={CARD_HEADER_CLASS}>
                      <h2 className="text-[13px] font-semibold">Manga</h2>
                    </div>
                    <div className="px-5 py-3.5 text-xs text-muted-foreground leading-relaxed">
                      Chapters open in the built-in reader. Reading progress is tracked and synced to AniList, so your library stays up to date
                      without a second app.
                    </div>
                  </section>
                </div>
              )}

            </div>
          </div>

          {/* Footer nav */}
          <div className="shrink-0 border-t border-border px-10 py-3.5 flex items-center justify-between bg-foreground/[0.02]">
            <button
              onClick={() => go(Math.max(1, step - 1) as Step)}
              className="bg-transparent border-none py-1.5 text-[13px] text-muted-foreground hover:text-foreground cursor-pointer transition-colors"
              style={{ visibility: step === 1 ? "hidden" : "visible" }}
            >
              Back
            </button>
            <div className="flex items-center gap-4">
              {skipLabel && (
                <button
                  onClick={onSkip}
                  className="bg-transparent border-none py-1.5 text-[13px] text-muted-foreground hover:text-foreground cursor-pointer transition-colors"
                >
                  {skipLabel}
                </button>
              )}
              <button
                onClick={() => (step === LAST_STEP ? handleFinish() : go((step + 1) as Step))}
                className="bg-accent hover:bg-accent-light text-black border-none rounded-[10px] px-5 py-2.5 text-[13px] font-semibold cursor-pointer transition-colors"
              >
                {step === LAST_STEP ? "Start watching" : "Continue"}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
