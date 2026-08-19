import { useQuery } from "@tanstack/react-query";
import { MediaRow } from "@/components/media/MediaRow";
import { mediaApi, type CinemaRow, type MediaItem } from "@/lib/api";
import { useAppStore } from "@/stores/app";

interface CinemaHomeViewProps {
  onSelect: (item: MediaItem, action?: "play", episode?: string | null) => void;
}

/** The rows the cinema home is built from, in the order they appear. Fixed for
 *  now — the anime home's row customization is driven by watch history, and
 *  cinema mode has none to sort by yet. */
const ROWS: { id: CinemaRow; title: string }[] = [
  { id: "trending_movies", title: "Trending Films" },
  { id: "trending_series", title: "Trending Series" },
  { id: "now_playing", title: "In Cinemas Now" },
  { id: "popular_series", title: "Popular Series" },
  { id: "top_rated_movies", title: "Highest Rated Films" },
];

function RowSkeleton({ title }: { title: string }) {
  return (
    <div className="space-y-4 animate-pulse px-1">
      <div className="h-6 w-48 rounded-md bg-white/10" />
      <div className="flex space-x-4 overflow-hidden">
        {[1, 2, 3, 4, 5, 6].map((i) => (
          <div key={i} className="h-[270px] w-[180px] shrink-0 rounded-lg bg-white/10" />
        ))}
      </div>
    </div>
  );
}

function CinemaRowSection({
  row,
  onSelect,
}: {
  row: { id: CinemaRow; title: string };
  onSelect: CinemaHomeViewProps["onSelect"];
}) {
  // Cinema keys are namespaced so they can never collide with the anime home's
  // rows, which are cached under their own names in the same query client.
  const query = useQuery({
    queryKey: ["cinema-row", row.id],
    queryFn: () => mediaApi.cinemaRow(row.id),
  });

  if (query.isLoading) return <RowSkeleton title={row.title} />;
  if (!query.data?.media?.length) return null;
  return <MediaRow title={row.title} items={query.data.media} onSelect={onSelect} />;
}

/** Shown when TMDB has no token yet: an empty grid would read as "nothing to
 *  watch" rather than "not set up". */
function NeedsToken() {
  const setCurrentView = useAppStore((s) => s.setCurrentView);

  return (
    <div className="flex min-h-[60vh] items-center justify-center px-8">
      <div className="max-w-[420px] text-center">
        <div className="meta-mono mb-3 text-muted-foreground">Cinema mode</div>
        <h2 className="mb-3 text-[22px] font-semibold text-foreground">Add a TMDB token</h2>
        <p className="mb-6 text-[13px] leading-relaxed text-muted-foreground">
          Movie and series details come from TMDB. Getting a token is free, and it goes in Settings
          under General.
        </p>
        <button
          onClick={() => setCurrentView("settings")}
          className="cursor-pointer rounded-md border border-border px-3 py-2 text-[12px] text-muted-foreground hover:border-foreground/25 hover:text-foreground"
        >
          Open Settings
        </button>
      </div>
    </div>
  );
}

/** What is part-watched, newest first.
 *
 *  Read from the local library rather than a tracking service — see
 *  `CinemaLibraryView` for why there isn't one. */
function ContinueRow({ onSelect }: { onSelect: CinemaHomeViewProps["onSelect"] }) {
  const library = useQuery({
    queryKey: ["cinema-library"],
    queryFn: () => mediaApi.cinemaLibrary(),
  });

  const inProgress = (library.data ?? [])
    .filter((e) => (e.entry.status ?? "CURRENT") === "CURRENT")
    .sort((a, b) => (b.entry.updated_at ?? "").localeCompare(a.entry.updated_at ?? ""))
    .map((e) => e.media);

  if (!inProgress.length) return null;
  return <MediaRow title="Continue watching" items={inProgress} onSelect={onSelect} />;
}

export function CinemaHomeView({ onSelect }: CinemaHomeViewProps) {
  const configured = useQuery({
    queryKey: ["cinema-configured"],
    queryFn: () => mediaApi.cinemaConfigured(),
    staleTime: 60_000,
  });

  if (configured.isLoading) return null;
  if (configured.data === false) return <NeedsToken />;

  return (
    <div className="space-y-10 px-8 py-8">
      <header>
        <h1 className="text-[26px] font-semibold text-foreground">Movies and series</h1>
        <p className="meta-mono mt-1 text-muted-foreground">From TMDB</p>
      </header>

      <ContinueRow onSelect={onSelect} />

      {ROWS.map((row) => (
        <CinemaRowSection key={row.id} row={row} onSelect={onSelect} />
      ))}
    </div>
  );
}
