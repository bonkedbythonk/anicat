interface WatchGridProps {
  total: number;
  progress: number;
  /** Highest episode number actually available to play (aired + sourced). */
  latestAvailable?: number;
  isManga: boolean;
  onPlay: (episode: number) => void;
}

/** One square per episode: filled = watched, outlined = next up, plain =
 * unwatched, dimmed = not aired yet. The whole season is legible in one
 * glance; clicking a square plays (or reads) that entry directly. */
export function WatchGrid({ total, progress, latestAvailable, isManga, onPlay }: WatchGridProps) {
  if (!total || total < 2) return null;

  const current = progress + 1;
  const squares = Array.from({ length: total }, (_, i) => i + 1);

  return (
    <div className="mb-5">
      <div className="flex flex-wrap gap-1.5 max-h-[150px] overflow-y-auto pr-1">
        {squares.map((n) => {
          const watched = n <= progress;
          const isCurrent = n === current;
          const unaired = latestAvailable != null && latestAvailable > 0 && n > latestAvailable;
          return (
            <button
              key={n}
              onClick={() => !unaired && onPlay(n)}
              disabled={unaired}
              title={
                unaired
                  ? `${isManga ? "Chapter" : "Episode"} ${n} — not out yet`
                  : `${watched ? "Rewatch" : isCurrent ? "Continue with" : "Play"} ${isManga ? "chapter" : "episode"} ${n}`
              }
              className={`watch-sq ${watched ? "watched" : ""} ${isCurrent ? "current" : ""} ${
                unaired ? "opacity-35 cursor-default" : ""
              }`}
            >
              {n}
            </button>
          );
        })}
      </div>
      <p className="meta-mono mt-2.5 text-muted-foreground">
        {progress} of {total} {isManga ? "read" : "watched"}
        {current <= total ? ` · up next ${isManga ? "CH" : "EP"} ${current}` : ""}
      </p>
    </div>
  );
}
