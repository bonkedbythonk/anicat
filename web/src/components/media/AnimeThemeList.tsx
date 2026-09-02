import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  Music,
  Play,
  X,
  ExternalLink,
  Volume2,
  Disc3,
  Loader2,
} from "lucide-react";
import { mediaApi, type AnimeTheme } from "@/lib/api";

interface AnimeThemeListProps {
  mediaId: number;
}

export function AnimeThemeList({ mediaId }: AnimeThemeListProps) {
  const [activeVideo, setActiveVideo] = useState<{ title: string; url: string } | null>(null);

  const { data: themes = [], isLoading } = useQuery({
    queryKey: ["anime-themes", mediaId],
    queryFn: () => mediaApi.fetchAnimeThemes(mediaId),
    staleTime: 24 * 60 * 60 * 1000,
  });

  if (isLoading) {
    return (
      <div className="py-6 flex items-center justify-center gap-2 text-muted-foreground">
        <Loader2 className="animate-spin text-accent" size={18} />
        <span className="text-xs font-mono">Loading theme songs...</span>
      </div>
    );
  }

  if (!themes || themes.length === 0) {
    return null;
  }

  const ops = themes.filter((t) => t.type === "OP");
  const eds = themes.filter((t) => t.type === "ED");

  return (
    <div className="space-y-4">
      <div className="flex items-center gap-2 font-semibold text-foreground text-xs">
        <Disc3 size={15} className="text-accent animate-spin-slow" />
        <span>Theme Songs (OP & ED)</span>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
        {/* Openings Column */}
        {ops.length > 0 && (
          <div className="space-y-2">
            <span className="font-mono text-[10.5px] uppercase tracking-wider text-muted-foreground font-bold flex items-center gap-1.5">
              <span className="px-1.5 py-0.2 rounded bg-accent/20 text-accent font-bold">OP</span>
              Opening Themes
            </span>
            <div className="space-y-1.5">
              {ops.map((theme) => (
                <ThemeCard
                  key={theme.id}
                  theme={theme}
                  onPlayVideo={(title, url) => setActiveVideo({ title, url })}
                />
              ))}
            </div>
          </div>
        )}

        {/* Endings Column */}
        {eds.length > 0 && (
          <div className="space-y-2">
            <span className="font-mono text-[10.5px] uppercase tracking-wider text-muted-foreground font-bold flex items-center gap-1.5">
              <span className="px-1.5 py-0.2 rounded bg-foreground/10 text-foreground/80 font-bold">ED</span>
              Ending Themes
            </span>
            <div className="space-y-1.5">
              {eds.map((theme) => (
                <ThemeCard
                  key={theme.id}
                  theme={theme}
                  onPlayVideo={(title, url) => setActiveVideo({ title, url })}
                />
              ))}
            </div>
          </div>
        )}
      </div>

      {/* In-app theme clip player modal */}
      {activeVideo && (
        <div
          className="fixed inset-0 z-50 bg-black/80 backdrop-blur-md flex items-center justify-center p-4 animate-fade-in"
          onClick={() => setActiveVideo(null)}
        >
          <div
            className="w-full max-w-2xl bg-surface rounded-2xl border border-border overflow-hidden shadow-2xl animate-scale-in"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="p-4 border-b border-border flex items-center justify-between gap-3">
              <div className="flex items-center gap-2 min-w-0">
                <Music size={16} className="text-accent shrink-0" />
                <span className="text-sm font-bold text-foreground truncate">
                  {activeVideo.title}
                </span>
              </div>
              <button
                onClick={() => setActiveVideo(null)}
                className="p-1 rounded-lg text-muted-foreground hover:text-foreground hover:bg-foreground/10 transition-colors cursor-pointer"
              >
                <X size={18} />
              </button>
            </div>

            <div className="aspect-video bg-black flex items-center justify-center relative">
              <video
                src={activeVideo.url}
                controls
                autoPlay
                className="w-full h-full object-contain"
              />
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

function ThemeCard({
  theme,
  onPlayVideo,
}: {
  theme: AnimeTheme;
  onPlayVideo: (title: string, url: string) => void;
}) {
  const searchQuery = encodeURIComponent(`${theme.title} ${theme.artists.join(" ")}`);
  const spotifyUrl = `https://open.spotify.com/search/${searchQuery}`;
  const youtubeUrl = `https://www.youtube.com/results?search_query=${searchQuery}`;

  return (
    <div className="p-2.5 rounded-xl border border-border bg-foreground/[0.02] hover:bg-foreground/[0.04] transition-colors flex items-center justify-between gap-3">
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="font-mono text-[10px] text-muted-foreground font-bold">
            {theme.type}
            {theme.sequence ? ` ${theme.sequence}` : ""}
          </span>
          <span className="text-xs font-bold text-foreground truncate">
            {theme.title}
          </span>
        </div>
        {theme.artists.length > 0 && (
          <p className="text-[11px] text-muted-foreground truncate mt-0.5">
            {theme.artists.join(", ")}
          </p>
        )}
      </div>

      <div className="flex items-center gap-1.5 shrink-0">
        {theme.videoUrl && (
          <button
            onClick={() => onPlayVideo(`${theme.type}${theme.sequence || ""} - ${theme.title}`, theme.videoUrl!)}
            className="flex items-center gap-1 px-2 py-1 rounded-md bg-accent/15 hover:bg-accent hover:text-background text-accent text-[10px] font-bold font-mono transition-all cursor-pointer"
            title="Watch Opening/Ending clip"
          >
            <Play size={10} fill="currentColor" />
            <span>Clip</span>
          </button>
        )}

        <a
          href={spotifyUrl}
          target="_blank"
          rel="noreferrer"
          className="p-1 rounded-md text-muted-foreground/70 hover:text-emerald-400 hover:bg-foreground/10 transition-colors"
          title="Search on Spotify"
        >
          <Volume2 size={13} />
        </a>

        <a
          href={youtubeUrl}
          target="_blank"
          rel="noreferrer"
          className="p-1 rounded-md text-muted-foreground/70 hover:text-red-400 hover:bg-foreground/10 transition-colors"
          title="Search on YouTube"
        >
          <ExternalLink size={13} />
        </a>
      </div>
    </div>
  );
}
