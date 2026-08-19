import { useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Loader2, X } from "lucide-react";
import { MediaCard } from "@/components/media/MediaCard";
import { mediaApi, type MediaItem } from "@/lib/api";
import { useSpatialNavigation } from "@/focus";

interface CinemaLibraryViewProps {
  onSelect: (item: MediaItem) => void;
}

/** Cinema mode's library.
 *
 *  Held in SQLite rather than on a tracking service. Trakt was meant to be the
 *  counterpart to AniList here, but creating an API application for it now
 *  requires a paid account, so the local `local_library` table — which had sat
 *  unused since before cinema mode existed — carries watched state instead.
 *  Nothing here forecloses a sync layer later; it would fill the same table. */
const TABS = [
  { id: "CURRENT", label: "Watching" },
  { id: "COMPLETED", label: "Watched" },
  { id: "PLANNING", label: "Watchlist" },
] as const;

type TabId = (typeof TABS)[number]["id"];

export function CinemaLibraryView({ onSelect }: CinemaLibraryViewProps) {
  const [activeTab, setActiveTab] = useState<TabId>("CURRENT");
  const queryClient = useQueryClient();
  useSpatialNavigation();

  const library = useQuery({
    queryKey: ["cinema-library"],
    queryFn: () => mediaApi.cinemaLibrary(),
  });

  const remove = async (mediaId: number) => {
    await mediaApi.cinemaRemoveFromLibrary(mediaId);
    queryClient.invalidateQueries({ queryKey: ["cinema-library"], refetchType: "all" });
  };

  const entries = library.data ?? [];
  const shown = entries.filter((e) => (e.entry.status ?? "CURRENT") === activeTab);

  return (
    <div className="space-y-8 px-8 py-8">
      <header>
        <h1 className="text-[26px] font-semibold text-foreground">Your library</h1>
        <p className="meta-mono mt-1 text-muted-foreground">Movies and series, kept on this machine</p>
      </header>

      <div className="flex gap-2">
        {TABS.map((tab) => {
          const count = entries.filter((e) => (e.entry.status ?? "CURRENT") === tab.id).length;
          return (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id)}
              aria-current={activeTab === tab.id ? "true" : undefined}
              className={`cursor-pointer rounded-md px-3 py-1.5 text-[13px] ${
                activeTab === tab.id
                  ? "bg-accent/12 font-semibold text-foreground"
                  : "text-muted-foreground hover:text-foreground"
              }`}
            >
              {tab.label}
              <span className="meta-mono ml-2 text-muted-foreground">{count}</span>
            </button>
          );
        })}
      </div>

      {library.isLoading ? (
        <div className="flex justify-center py-16">
          <Loader2 className="animate-spin text-accent" size={28} />
        </div>
      ) : shown.length === 0 ? (
        <p className="py-16 text-center text-[13px] text-muted-foreground">
          {activeTab === "COMPLETED"
            ? "Nothing finished yet. Watching something past 85% files it here."
            : activeTab === "CURRENT"
              ? "Nothing in progress. Play a film or an episode and it shows up here."
              : "Nothing on the watchlist yet."}
        </p>
      ) : (
        <div
          role="list"
          className="grid grid-cols-2 gap-5 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6"
        >
          {shown.map(({ entry, media }) => (
            <div key={entry.media_id} role="listitem" className="group/entry relative">
              <MediaCard item={media} onSelect={onSelect} />
              <button
                onClick={() => remove(entry.media_id)}
                aria-label={`Remove ${media.title?.english || media.title?.romaji || "this title"} from your library`}
                className="absolute right-1.5 top-1.5 hidden rounded-full bg-black/70 p-1.5 text-white group-hover/entry:block focus-visible:block"
              >
                <X size={13} aria-hidden="true" />
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
