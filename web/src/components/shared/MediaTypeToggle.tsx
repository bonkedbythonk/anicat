import type { MediaSearchType } from "@/lib/types";

const LABELS: Record<MediaSearchType, string> = {
  ALL: "All",
  ANIME: "Anime",
  MANGA: "Manga",
};

/** Generic over the option set so each caller keeps its own narrow type:
 *  library lists stay "ANIME" | "MANGA", while search opts into "ALL" by
 *  passing it explicitly. Widening the prop to MediaSearchType for every
 *  caller would let "ALL" reach surfaces that have no combined mode. */
export function MediaTypeToggle<T extends MediaSearchType>({
  value,
  onChange,
  options,
}: {
  value: T;
  onChange: (v: T) => void;
  options?: readonly T[];
}) {
  const opts = options ?? (["ANIME", "MANGA"] as readonly MediaSearchType[] as readonly T[]);
  return (
    <div className="flex rounded-md overflow-hidden border border-border">
      {opts.map((t) => (
        <button
          key={t}
          onClick={() => onChange(t)}
          className={`px-3 py-1.5 text-[12px] font-medium cursor-pointer ${
            value === t ? "bg-accent/15 text-accent" : "text-foreground/50 hover:text-foreground"
          }`}
        >
          {LABELS[t]}
        </button>
      ))}
    </div>
  );
}
