import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { useAppStore, setPlayback } from "@/stores/app";
import {
  getAnimeDetail,
  getCharacters,
  getEpisodes,
  updateMediaEntry,
  resolveStream,
} from "@/lib/api";
import type { MediaItem, Episode } from "@/lib/types";
import { X, Play, Star } from "lucide-react";

export function MediaDetail({ item }: { item: MediaItem }) {
  const closeDetail = useAppStore((s) => s.closeDetail);
  const queryClient = useQueryClient();
  const title = item.title.romaji || item.title.english || "Unknown";

  const detail = useQuery({
    queryKey: ["media-detail", item.id],
    queryFn: () => getAnimeDetail(item.id),
    staleTime: 300_000,
    enabled: !item.description, // skip if we already have full data
  });

  const chars = useQuery({
    queryKey: ["media-characters", item.id],
    queryFn: () => getCharacters(item.id),
    staleTime: 600_000,
  });

  const episodes = useQuery({
    queryKey: ["media-episodes", item.id],
    queryFn: () => getEpisodes(item.id),
    staleTime: 120_000,
  });

  const updateMutation = useMutation({
    mutationFn: (updates: Record<string, unknown>) => updateMediaEntry(item.id, updates),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ["library"] });
      queryClient.invalidateQueries({ queryKey: ["media-detail", item.id] });
    },
  });

  const media = detail.data?.data?.Media || item;
  const characterEdges = chars.data?.data?.Media?.characters?.edges || [];
  const episodeList: Episode[] = episodes.data || [];
  const entry = media.mediaListEntry;

  const handleStatusChange = (status: string) => {
    updateMutation.mutate({ status });
  };

  const handlePlay = async (ep: Episode) => {
    try {
      const servers = await resolveStream(item.id, ep.number);
      const server = servers[0]?.url || "";
      setPlayback(
        media,
        ep,
        "gogoanime",
        server,
      );
    } catch {
      // toast error handled by caller
    }
  };

  return (
    <div className="absolute inset-y-0 right-0 w-[420px] bg-[var(--bg-secondary)] border-l border-[var(--border)] shadow-2xl z-40 flex flex-col animate-slide-in">
      {/* Header */}
      <div className="flex items-center justify-between p-4 border-b border-[var(--border)] shrink-0">
        <h3 className="font-semibold text-[var(--text-primary)] truncate pr-4">{title}</h3>
        <button
          onClick={closeDetail}
          className="text-[var(--text-muted)] hover:text-[var(--text-primary)] transition-colors"
        >
          <X size={18} />
        </button>
      </div>

      <div className="flex-1 overflow-y-auto p-4 space-y-4">
        {/* Cover */}
        {media.coverImage?.large && (
          <img src={media.coverImage.large} alt={title} className="w-full rounded-lg" />
        )}

        {/* Genres */}
        {media.genres && (
          <div className="flex gap-2 flex-wrap">
            {media.genres.map((g) => (
              <span
                key={g}
                className="px-2 py-0.5 text-xs rounded-full bg-[var(--bg-tertiary)] text-[var(--text-secondary)]"
              >
                {g}
              </span>
            ))}
          </div>
        )}

        {/* Actions */}
        <div className="flex gap-2">
          <button
            onClick={() => handleStatusChange("CURRENT")}
            className="flex-1 py-2 rounded-lg text-sm font-medium bg-[var(--accent)] text-white hover:bg-[var(--accent-hover)] transition-colors"
          >
            Watching
          </button>
          <button
            onClick={() => handleStatusChange("PLANNING")}
            className="flex-1 py-2 rounded-lg text-sm font-medium bg-[var(--bg-tertiary)] text-[var(--text-primary)] hover:bg-[var(--border)] transition-colors"
          >
            Plan to Watch
          </button>
          <button
            onClick={() => handleStatusChange("COMPLETED")}
            className="flex-1 py-2 rounded-lg text-sm font-medium bg-[var(--bg-tertiary)] text-[var(--text-primary)] hover:bg-[var(--border)] transition-colors"
          >
            Completed
          </button>
        </div>

        {/* Stats grid */}
        <div className="grid grid-cols-2 gap-2 text-sm">
          {media.format && (
            <div>
              <span className="text-[var(--text-muted)]">Format</span>
              <p className="text-[var(--text-primary)] font-medium">{media.format}</p>
            </div>
          )}
          {media.status && (
            <div>
              <span className="text-[var(--text-muted)]">Status</span>
              <p className="text-[var(--text-primary)] font-medium">{media.status}</p>
            </div>
          )}
          {media.episodes && (
            <div>
              <span className="text-[var(--text-muted)]">Episodes</span>
              <p className="text-[var(--text-primary)] font-medium">{media.episodes}</p>
            </div>
          )}
          {media.averageScore && (
            <div>
              <span className="text-[var(--text-muted)]">Score</span>
              <p className="text-[var(--text-primary)] font-medium">{media.averageScore}%</p>
            </div>
          )}
          {media.season && (
            <div>
              <span className="text-[var(--text-muted)]">Season</span>
              <p className="text-[var(--text-primary)] font-medium">
                {media.season} {media.seasonYear}
              </p>
            </div>
          )}
          {media.duration && (
            <div>
              <span className="text-[var(--text-muted)]">Duration</span>
              <p className="text-[var(--text-primary)] font-medium">{media.duration} min</p>
            </div>
          )}
        </div>

        {/* Description */}
        {media.description && (
          <div>
            <h4 className="text-sm font-medium text-[var(--text-primary)] mb-1">Synopsis</h4>
            <p
              className="text-sm text-[var(--text-secondary)] leading-relaxed"
              dangerouslySetInnerHTML={{ __html: media.description }}
            />
          </div>
        )}

        {/* Episodes */}
        {episodeList.length > 0 && (
          <div>
            <h4 className="text-sm font-medium text-[var(--text-primary)] mb-2">
              Episodes ({episodeList.length})
            </h4>
            <div className="space-y-1 max-h-80 overflow-y-auto">
              {episodeList.map((ep) => (
                <button
                  key={ep.number}
                  onClick={() => handlePlay(ep)}
                  className="w-full flex items-center gap-3 p-2 rounded-lg hover:bg-[var(--bg-tertiary)] transition-colors text-left"
                >
                  <Play size={14} className="text-[var(--accent)] shrink-0" />
                  <span className="text-sm text-[var(--text-primary)]">
                    Ep {ep.number}
                  </span>
                  {ep.title && (
                    <span className="text-xs text-[var(--text-muted)] truncate">
                      {ep.title}
                    </span>
                  )}
                </button>
              ))}
            </div>
          </div>
        )}

        {/* Characters */}
        {characterEdges.length > 0 && (
          <div>
            <h4 className="text-sm font-medium text-[var(--text-primary)] mb-2">
              Characters
            </h4>
            <div className="flex gap-3 overflow-x-auto pb-2">
              {characterEdges.slice(0, 12).map((edge) => (
                <div key={edge.node.id} className="shrink-0 text-center w-16">
                  {edge.node.image?.large && (
                    <img
                      src={edge.node.image.large}
                      alt={edge.node.name.full}
                      className="w-14 h-14 rounded-full object-cover mx-auto"
                    />
                  )}
                  <p className="text-[10px] text-[var(--text-primary)] mt-1 truncate">
                    {edge.node.name.full}
                  </p>
                  <p className="text-[10px] text-[var(--text-muted)]">{edge.role}</p>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Entry details */}
        {entry && (
          <div className="bg-[var(--bg-tertiary)] rounded-lg p-3">
            <h4 className="text-sm font-medium text-[var(--text-primary)] mb-2">
              Your Progress
            </h4>
            <div className="space-y-1 text-xs">
              <div className="flex justify-between">
                <span className="text-[var(--text-muted)]">Status</span>
                <span className="text-[var(--text-primary)]">{entry.status}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-[var(--text-muted)]">Progress</span>
                <span className="text-[var(--text-primary)]">
                  {entry.progress || 0} / {media.episodes || "?"}
                </span>
              </div>
              {entry.score > 0 && (
                <div className="flex justify-between">
                  <span className="text-[var(--text-muted)]">Score</span>
                  <span className="text-[var(--accent)]">
                    <Star size={12} className="inline mr-0.5" />
                    {entry.score}
                  </span>
                </div>
              )}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
