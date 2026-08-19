import { useAppStore } from "@/stores/app";

/** Cinema mode's stand-in until TMDB metadata lands.
 *
 *  Every cinema view routes here for now. It exists so the mode switch is a
 *  real, testable thing on its own — the shell flips, the nav changes, anime
 *  mode is provably untouched — without a metadata backend behind it yet.
 *  Each view names what will replace it so an empty screen still says
 *  something true. */
export function CinemaPlaceholderView() {
  const currentView = useAppStore((s) => s.currentView);
  const setAppMode = useAppStore((s) => s.setAppMode);

  // Home and Search render for real now; Library is the one left, because it
  // needs watch data rather than catalog data.
  const copy: Record<string, { title: string; body: string }> = {
    lists: {
      title: "Your movie library",
      body: "Watched, watchlist and ratings, held locally and synced with Trakt once an account is connected.",
    },
  };

  const { title, body } = copy[currentView] ?? copy.lists;

  return (
    <div className="flex min-h-[60vh] items-center justify-center px-8">
      <div className="max-w-[420px] text-center">
        <div className="meta-mono mb-3 text-muted-foreground">Cinema mode</div>
        <h2 className="mb-3 text-[22px] font-semibold text-foreground">{title}</h2>
        <p className="mb-6 text-[13px] leading-relaxed text-muted-foreground">{body}</p>
        <button
          onClick={() => setAppMode("anime")}
          className="rounded-md border border-border px-3 py-2 text-[12px] text-muted-foreground hover:border-foreground/25 hover:text-foreground cursor-pointer"
        >
          Back to anime and manga
        </button>
      </div>
    </div>
  );
}
