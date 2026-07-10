import { useEffect, useRef, useState } from "react";
import { Play, Info } from "lucide-react";
import { proxyImage } from "@/lib/proxy";
import type { MediaItem } from "@/lib/types";

interface MobileHeroProps {
  items: MediaItem[];
  onSelect: (item: MediaItem, action?: "play", episode?: string | null) => void;
}

/** Full-bleed backdrop carousel — the Netflix/Crunchyroll "what to watch
 * next" moment. Deliberately much lighter than the shared desktop `Hero`
 * (no side "Up Next" panel, no inline badge system, no countdown timers):
 * one image, one title, one line of metadata, one primary action. */
export function MobileHero({ items, onSelect }: MobileHeroProps) {
  const [index, setIndex] = useState(0);
  const touchX = useRef<number | null>(null);
  const item = items[Math.min(index, items.length - 1)];

  useEffect(() => {
    if (items.length <= 1) return;
    const timer = setInterval(() => setIndex((i) => (i + 1) % items.length), 7000);
    return () => clearInterval(timer);
  }, [items.length]);

  if (!item) {
    return <div className="aspect-[16/10] w-full animate-pulse rounded-2xl bg-surface" />;
  }

  const title = item.title?.english || item.title?.romaji || "Unknown";
  const backdrop = item.banner_image || item.cover_image?.large || item.cover_image?.medium;
  const progress = item.user_status?.progress || 0;
  const nextEp = String(progress + 1);
  const isManga = item.type === "MANGA";

  const onTouchStart = (e: React.TouchEvent) => { touchX.current = e.touches[0].clientX; };
  const onTouchEnd = (e: React.TouchEvent) => {
    if (touchX.current === null || items.length <= 1) return;
    const dx = e.changedTouches[0].clientX - touchX.current;
    if (Math.abs(dx) > 50) setIndex((i) => (dx < 0 ? (i + 1) % items.length : (i - 1 + items.length) % items.length));
    touchX.current = null;
  };

  return (
    <div
      className="relative aspect-[16/10] w-full overflow-hidden rounded-2xl"
      onTouchStart={onTouchStart}
      onTouchEnd={onTouchEnd}
    >
      <img src={proxyImage(backdrop)} alt={title} className="absolute inset-0 h-full w-full object-cover" />
      <div className="absolute inset-0 bg-gradient-to-t from-background via-background/40 to-transparent" />
      <div className="absolute inset-0 bg-gradient-to-b from-background/50 via-transparent to-transparent h-24" />

      <div className="absolute bottom-0 left-0 right-0 px-6 pb-5 space-y-3">
        <h1 className="line-clamp-2 text-[26px] font-extrabold leading-tight text-white drop-shadow-lg">{title}</h1>
        <div className="flex items-center gap-2 text-xs font-semibold text-white/70">
          {item.average_score && <span className="text-amber-400">★ {item.average_score}%</span>}
          {item.seasonYear && <span>{item.seasonYear}</span>}
          {item.genres?.[0] && <span>{item.genres[0]}</span>}
        </div>
        <div className="flex items-center gap-2.5 pt-1">
          <button
            onClick={() => onSelect(item, "play", nextEp)}
            className="flex flex-1 items-center justify-center gap-2 rounded-full bg-white py-3 text-[15px] font-bold text-black active:scale-95 transition-transform"
          >
            <Play size={17} fill="currentColor" />
            {isManga ? `Read Ch. ${nextEp}` : `Play EP ${nextEp}`}
          </button>
          <button
            onClick={() => onSelect(item)}
            className="flex h-[46px] w-[46px] items-center justify-center rounded-full bg-white/15 text-white active:scale-95 transition-transform"
          >
            <Info size={19} />
          </button>
        </div>
        {items.length > 1 && (
          <div className="flex justify-center gap-1.5 pt-1">
            {items.map((_, i) => (
              <div key={i} className={`h-1.5 rounded-full transition-all ${i === index ? "w-4 bg-white" : "w-1.5 bg-white/30"}`} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
