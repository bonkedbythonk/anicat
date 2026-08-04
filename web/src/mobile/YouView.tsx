import { ChevronRight } from "lucide-react";
import { useQuery } from "@tanstack/react-query";
import { mediaApi, getUserLists } from "@/lib/api";
import { useAppStore, useSettingsStore } from "@/stores/app";
import { saveMobileSetting } from "./mobileSettings";

interface YouViewProps {
  displayName: string;
  anilistUsername: string | null;
  onNavigate: (view: "schedule" | "notifications" | "profile") => void;
  onLogout: () => void;
}

const PROVIDERS = ["anineko", "nyaa"] as const;
const PROVIDER_LABELS: Record<string, string> = { anineko: "AniNeko", nyaa: "Torrents" };

function Row({
  label,
  explainer,
  onClick,
  children,
  first,
}: {
  label: string;
  explainer?: string;
  onClick?: () => void;
  children?: React.ReactNode;
  first?: boolean;
}) {
  return (
    <button
      onClick={onClick}
      className={`w-full flex items-center gap-4 px-4 py-3 text-left ${onClick ? "active:bg-foreground/[0.06]" : "cursor-default"} transition-colors ${
        first ? "" : "border-t border-border"
      }`}
    >
      <span className="min-w-0 flex-1">
        <span className="block text-[14px] font-medium text-foreground">{label}</span>
        {explainer && <span className="mt-0.5 block text-[11.5px] leading-snug text-muted-foreground">{explainer}</span>}
      </span>
      {children}
    </button>
  );
}

function Toggle({ on, onChange }: { on: boolean; onChange: (v: boolean) => void }) {
  return (
    <span
      role="switch"
      aria-checked={on}
      onClick={(e) => {
        e.stopPropagation();
        onChange(!on);
      }}
      className={`relative inline-block h-[22px] w-[38px] shrink-0 rounded-full transition-colors duration-200 ${
        on ? "bg-accent" : "bg-foreground/[0.16]"
      }`}
    >
      <span
        className={`absolute top-[2px] h-[18px] w-[18px] rounded-full bg-background shadow transition-all duration-200 ${
          on ? "left-[18px]" : "left-[2px]"
        }`}
      />
    </span>
  );
}

/** List counts for the stats strip. Deliberately not `mediaApi.getUserList`:
 * that helper slices its result to 50 entries a page, so a completed list of
 * any real size would report a confidently wrong number. `getUserLists` is
 * the same single request without the slicing. */
function useListCounts(enabled: boolean) {
  const { data } = useQuery({
    queryKey: ["you-list-counts"],
    queryFn: async () => {
      const [current, completed] = await Promise.all([
        getUserLists(undefined, "CURRENT", "ANIME"),
        getUserLists(undefined, "COMPLETED", "ANIME"),
      ]);
      const count = (res: Awaited<ReturnType<typeof getUserLists>>) =>
        (res?.MediaListCollection?.lists ?? []).reduce((n, l) => n + (l.entries?.length ?? 0), 0);
      return { watching: count(current), completed: count(completed) };
    },
    enabled,
  });
  return data;
}

function Stat({ value, label, last }: { value: string; label: string; last?: boolean }) {
  return (
    <div className={`px-2 py-3 text-center ${last ? "" : "border-r border-border"}`}>
      <p className="text-[16px] font-bold tabular-nums text-foreground">{value}</p>
      <p className="mt-0.5 font-mono text-[9px] uppercase tracking-[0.06em] text-muted-foreground">{label}</p>
    </div>
  );
}

/** The account tab in the Ink & Index settings idiom: grouped rows on quiet
 * surfaces, plain words (no icon squares), one-line explanations, mono
 * values. Playback settings are per-device via mobileSettings, never
 * written to the server's global config.toml. */
export function YouView({ displayName, anilistUsername, onNavigate, onLogout }: YouViewProps) {
  const autoplay = useSettingsStore((s) => s.autoplay);
  const autoskip = useSettingsStore((s) => s.autoskip);
  const provider = useSettingsStore((s) => s.defaultProvider);
  const apiConnected = useAppStore((s) => s.apiConnected);
  const isAuthenticated = useAppStore((s) => s.apiAuthenticated);
  const counts = useListCounts(isAuthenticated);
  const { data: profile } = useQuery({
    queryKey: ["profile"],
    queryFn: () => mediaApi.getProfile(),
    enabled: isAuthenticated,
  });
  const meanScore = profile?.mean_score ? Math.round(profile.mean_score) : null;

  const cycleProvider = () => {
    const idx = PROVIDERS.indexOf(provider as (typeof PROVIDERS)[number]);
    saveMobileSetting("defaultProvider", PROVIDERS[(idx + 1) % PROVIDERS.length]);
  };
  const groupClass = "rounded-md bg-surface border border-border overflow-hidden";
  const groupLabel = "px-1 pt-6 pb-1.5 font-mono text-[10px] uppercase tracking-[0.08em] text-muted-foreground";

  return (
    <div className="animate-fade-in pb-4">
      {/* Profile header */}
      <div className={groupClass}>
        <button
          onClick={() => onNavigate("profile")}
          className="w-full flex items-center gap-3.5 px-4 py-3.5 text-left active:bg-foreground/[0.06] transition-colors"
        >
          <div className="flex h-11 w-11 shrink-0 items-center justify-center rounded-full bg-accent/15 text-[17px] font-semibold text-accent">
            {displayName.charAt(0).toUpperCase()}
          </div>
          <div className="min-w-0 flex-1">
            <p className="text-[15px] font-semibold text-foreground truncate">{displayName}</p>
            <p className="font-mono text-[10.5px] tracking-[0.05em] text-muted-foreground truncate">
              {anilistUsername ? `AniList · ${anilistUsername}` : "AniList not connected"}
            </p>
          </div>
          <ChevronRight size={17} className="text-muted-foreground shrink-0" />
        </button>
        {/* Stats belong on the hub, not one tap deeper — the numbers are the
            reason to open this tab at all. */}
        <div className="grid grid-cols-3 border-t border-border">
          <Stat value={counts ? String(counts.watching) : "—"} label="Watching" />
          <Stat value={counts ? String(counts.completed) : "—"} label="Completed" />
          <Stat value={meanScore ? String(meanScore) : "—"} label="Mean score" last />
        </div>
      </div>

      <p className={groupLabel}>Playback</p>
      <div className={groupClass}>
        <Row first label="Source" explainer="Which provider this phone streams from." onClick={cycleProvider}>
          <span className="font-mono text-[11px] uppercase tracking-[0.07em] text-muted-foreground">{PROVIDER_LABELS[provider] || provider}</span>
          <ChevronRight size={15} className="text-muted-foreground shrink-0" />
        </Row>
        <Row
          label="Auto-play next episode"
          onClick={() => saveMobileSetting("autoplay", !autoplay)}
        >
          <Toggle on={autoplay} onChange={(v) => saveMobileSetting("autoplay", v)} />
        </Row>
        <Row
          label="Auto-skip intro and outro"
          onClick={() => saveMobileSetting("autoskip", !autoskip)}
        >
          <Toggle on={autoskip} onChange={(v) => saveMobileSetting("autoskip", v)} />
        </Row>
      </div>

      <p className={groupLabel}>Sections</p>
      <div className={groupClass}>
        <Row first label="Schedule" onClick={() => onNavigate("schedule")}>
          <ChevronRight size={15} className="text-muted-foreground shrink-0" />
        </Row>
      </div>

      <p className={groupLabel}>Server</p>
      <div className={groupClass}>
        <Row first label={window.location.hostname}>
          <span className={`font-mono text-[10.5px] uppercase tracking-[0.07em] ${apiConnected ? "text-[#7fa96b]" : "text-[#c07a5b]"}`}>
            {apiConnected ? "Connected" : "Unreachable"}
          </span>
        </Row>
        <button
          onClick={onLogout}
          className="w-full border-t border-border px-4 py-3 text-center text-[14px] font-medium text-[#c07a5b] active:bg-foreground/[0.06] transition-colors"
        >
          Log out
        </button>
      </div>
    </div>
  );
}
