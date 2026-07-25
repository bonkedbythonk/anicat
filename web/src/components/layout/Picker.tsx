import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
import { X } from "lucide-react";
import { mediaApi, type MediaItem } from "@/lib/api";
import { proxyImage } from "@/lib/proxy";
import { useAppStore } from "@/stores/app";
import { FocusScope, useFocusable } from "@/focus";
import { useModalDismiss } from "@/hooks/useModalDismiss";

type Mood = "continue" | "new";

const COMFY_GENRES = new Set(["Slice of Life", "Comedy", "Romance", "Sports", "Music"]);
const INTENSE_GENRES = new Set(["Thriller", "Horror", "Psychological", "Action", "Mystery"]);

interface Scored {
  item: MediaItem;
  score: number;
  reasons: string[];
}

function entryOf(m: MediaItem) {
  return m.user_status || m.media_list_entry || undefined;
}

/** Local scoring — no AI, no network beyond the lists already cached.
 * Weights: nearly-finished shows, freshly aired episodes, your own scores,
 * how recently you touched it, and time of night vs episode length. */
function scoreCandidates(
  watching: MediaItem[],
  planning: MediaItem[],
  mood: Mood,
  short: boolean,
  comfy: boolean,
  intense: boolean
): Scored[] {
  const hour = new Date().getHours();
  const lateNight = hour >= 22 || hour < 2;

  // Genre affinity from the shows you scored while watching.
  const affinity = new Map<string, number>();
  for (const m of watching) {
    const s = entryOf(m)?.score || 0;
    if (s <= 0) continue;
    for (const g of m.genres || []) affinity.set(g, (affinity.get(g) || 0) + s);
  }
  const maxAffinity = Math.max(1, ...affinity.values());

  const pool = mood === "continue" ? watching : planning;

  const scored: Scored[] = pool
    .filter((m) => {
      const genres = m.genres || [];
      if (short && (m.duration || 24) > 30 && (m.episodes || 99) > 13) return false;
      if (comfy && !genres.some((g) => COMFY_GENRES.has(g))) return false;
      if (intense && !genres.some((g) => INTENSE_GENRES.has(g))) return false;
      return true;
    })
    .map((m) => {
      const entry = entryOf(m);
      const progress = entry?.progress || 0;
      const total = m.episodes || 0;
      let score = 0;
      const reasons: string[] = [];

      if (mood === "continue") {
        const remaining = total > 0 ? total - progress : 99;
        if (remaining <= 0) return { item: m, score: -1, reasons };
        if (remaining <= 2 && m.status !== "RELEASING") {
          score += 30;
          reasons.push(`only ${remaining} episode${remaining === 1 ? "" : "s"} left — you could finish it`);
        }
        const released = m.next_airing?.episode ? m.next_airing.episode - 1 : total;
        if (m.status === "RELEASING" && progress < released) {
          score += 18;
          reasons.push("a new episode is out");
        }
        const userScore = entry?.score || 0;
        if (userScore > 0) {
          score += Math.min(20, userScore / 5);
          reasons.push("it's one of your highest-rated shows");
        }
        const updatedAt = Number(entry?.updated_at) || 0;
        if (updatedAt > 0) {
          const days = (Date.now() / 1000 - updatedAt) / 86_400;
          if (days >= 1 && days <= 10) {
            score += 10;
          } else if (days > 30) {
            score -= 5;
            reasons.push(`untouched for ${Math.floor(days)} days`);
          }
        }
        if (lateNight && (m.duration || 24) <= 26) {
          score += 8;
          reasons.push("short episodes suit a late night");
        }
      } else {
        const avg = m.average_score || m.averageScore || 0;
        if (avg > 0) {
          score += avg / 4;
          if (avg >= 80) reasons.push(`rated ${avg} on AniList`);
        }
        let aff = 0;
        for (const g of m.genres || []) aff += (affinity.get(g) || 0) / maxAffinity;
        if (aff > 0.5) {
          score += aff * 12;
          const top = (m.genres || []).filter((g) => affinity.has(g)).slice(0, 2).join(" and ");
          if (top) reasons.push(`you rate ${top} shows highly`);
        }
        score += Math.random() * 6; // gentle shuffle so rerolls vary
      }

      return { item: m, score, reasons };
    })
    .filter((s) => s.score >= 0)
    .sort((a, b) => b.score - a.score);

  return scored;
}

function FilterChip({
  label,
  active,
  onClick,
}: {
  label: string;
  active: boolean;
  onClick: () => void;
}) {
  const { ref, isFocused, tabIndex } = useFocusable<HTMLButtonElement>();
  return (
    <button
      ref={ref}
      tabIndex={tabIndex}
      onClick={() => {
        onClick();
      }}
      className={`meta-mono px-2.5 py-1.5 rounded-full border cursor-pointer ${
        active
          ? "border-transparent bg-accent/15 text-accent"
          : "border-border text-foreground/50 hover:text-foreground/80"
      } ${isFocused ? "focus-active" : ""}`}
    >
      {label}
    </button>
  );
}

function ActionButton({
  primary,
  onClick,
  children,
}: {
  primary?: boolean;
  onClick: () => void;
  children: ReactNode;
}) {
  const { ref, isFocused, tabIndex } = useFocusable<HTMLButtonElement>();
  return (
    <button
      ref={ref}
      tabIndex={tabIndex}
      onClick={onClick}
      className={`rounded-md px-4 py-2 text-[12.5px] font-medium cursor-pointer ${
        primary
          ? "bg-accent font-semibold text-black hover:bg-accent-light"
          : "border border-border text-foreground/70 hover:text-foreground hover:border-foreground/25"
      } ${isFocused ? "focus-active" : ""}`}
    >
      {children}
    </button>
  );
}

export function Picker() {
  const open = useAppStore((s) => s.pickerOpen);
  const setOpen = useAppStore((s) => s.setPickerOpen);
  const openDetail = useAppStore((s) => s.openDetail);
  const isAuthenticated = useAppStore((s) => s.apiAuthenticated);
  const activeFocusScope = useAppStore((s) => s.activeFocusScope);
  const setActiveFocusScope = useAppStore((s) => s.setActiveFocusScope);

  const [mood, setMood] = useState<Mood>("continue");
  const [short, setShort] = useState(false);
  const [comfy, setComfy] = useState(false);
  const [intense, setIntense] = useState(false);
  const [cursor, setCursor] = useState(0);
  const closeButtonRef = useRef<HTMLButtonElement>(null);

  const close = () => {
    setOpen(false);
    setCursor(0);
  };

  const modalRef = useModalDismiss<HTMLDivElement>(open, close);
  const previousScopeRef = useRef<string | null>(null);

  const watchingQ = useQuery({
    queryKey: ["home-watching"],
    queryFn: () => mediaApi.getUserList("watching", "ANIME"),
    enabled: open && isAuthenticated,
  });
  const planningQ = useQuery({
    queryKey: ["home-planning"],
    queryFn: () => mediaApi.getUserList("planning", "ANIME"),
    enabled: open && isAuthenticated,
  });

  const candidates = useMemo(
    () =>
      scoreCandidates(
        watchingQ.data?.media || [],
        planningQ.data?.media || [],
        mood,
        short,
        comfy,
        intense
      ),
    [watchingQ.data, planningQ.data, mood, short, comfy, intense]
  );

  useEffect(() => {
    if (!open) return;
    previousScopeRef.current = activeFocusScope;
    setActiveFocusScope("picker");
    const t = setTimeout(() => closeButtonRef.current?.focus(), 30);
    
    return () => {
      clearTimeout(t);
      setActiveFocusScope(previousScopeRef.current);
    };
  }, [open]);

  if (!open) return null;

  const pick = candidates[cursor % Math.max(1, candidates.length)];


  const entry = pick ? entryOf(pick.item) : undefined;
  const progress = entry?.progress || 0;
  const total = pick?.item.episodes || 0;

  return (
    <div 
      ref={modalRef}
      className="fixed inset-0 z-[300] bg-black/55 flex items-center justify-center p-6" 
      onClick={close}
      role="dialog"
      aria-modal="true"
      aria-label="Tonight's pick"
      tabIndex={-1}
    >
      <div
        className="w-[min(600px,94vw)] rounded-lg border border-border bg-surface shadow-2xl shadow-black/50 p-5 animate-fade-in-fast"
        onClick={(e) => e.stopPropagation()}
      >
        <FocusScope name="picker" orientation="vertical" className="contents">
          <div className="flex items-center justify-between mb-4">
            <span className="meta-mono text-muted-foreground">Tonight's pick</span>
            <button
              ref={closeButtonRef}
              onClick={close}
              aria-label="Close"
              className="p-1.5 rounded-md text-muted-foreground hover:text-foreground cursor-pointer"
            >
              <X size={15} />
            </button>
          </div>

          {!pick ? (
            <p className="meta-mono py-10 text-center text-muted-foreground">
              {watchingQ.isLoading || planningQ.isLoading ? "Thinking" : "Nothing matches those filters"}
            </p>
          ) : (
            <div className="flex gap-5">
              <PickCard item={pick.item} onClick={() => { close(); openDetail(pick.item); }} />
              <div className="flex-1 min-w-0 flex flex-col">
                <h3 className="text-[17px] font-semibold text-foreground leading-tight">
                  {pick.item.title.english || pick.item.title.romaji}
                </h3>
                <p className="meta-mono mt-2 text-muted-foreground flex gap-4 flex-wrap">
                  {mood === "continue" && <span>EP {progress + 1}{total ? ` / ${total}` : ""}</span>}
                  {pick.item.duration ? <span>{pick.item.duration} min</span> : null}
                  {pick.reasons[0] && <span className="text-accent">{pick.reasons[0]}</span>}
                </p>
                {pick.reasons.length > 1 && (
                  <p className="mt-3 text-[12.5px] leading-relaxed text-foreground/60 max-w-[42ch]">
                    Also: {pick.reasons.slice(1, 3).join("; ")}.
                  </p>
                )}
                <div className="flex flex-wrap gap-2 mt-4">
                  <FilterChip label="Continue" active={mood === "continue"} onClick={() => { setMood("continue"); setCursor(0); }} />
                  <FilterChip label="Something new" active={mood === "new"} onClick={() => { setMood("new"); setCursor(0); }} />
                  <FilterChip label="Short" active={short} onClick={() => { setShort((v) => !v); setCursor(0); }} />
                  <FilterChip label="Comfy" active={comfy} onClick={() => { setComfy((v) => !v); setCursor(0); }} />
                  <FilterChip label="Intense" active={intense} onClick={() => { setIntense((v) => !v); setCursor(0); }} />
                </div>
                <div className="flex gap-2.5 mt-auto pt-5">
                  <ActionButton
                    primary
                    onClick={() => {
                      close();
                      openDetail(pick.item, mood === "continue" ? "play" : undefined);
                    }}
                  >
                    Watch this
                  </ActionButton>
                  <ActionButton onClick={() => setCursor((c) => c + 1)}>Show another</ActionButton>
                </div>
              </div>
            </div>
          )}
        </FocusScope>
      </div>
    </div>
  );
}

function PickCard({ item, onClick }: { item: MediaItem; onClick: () => void }) {
  const { ref, isFocused, tabIndex } = useFocusable<HTMLButtonElement>();
  return (
    <button
      ref={ref}
      tabIndex={tabIndex}
      onClick={onClick}
      className={`w-[150px] shrink-0 cursor-pointer ${isFocused ? "focus-active" : ""}`}
    >
      <div className="relative aspect-[2/3] rounded-md overflow-hidden bg-background">
        <img
          src={proxyImage(item.cover_image?.large || item.cover_image?.medium)}
          alt=""
          className="absolute inset-0 w-full h-full object-cover"
        />
      </div>
    </button>
  );
}
