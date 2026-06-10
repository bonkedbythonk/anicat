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
    enabled: !item.description,
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

  const media = detail.data?.Media || item;
  const characterEdges = chars.data?.Media?.characters?.edges || [];
  const episodeList: Episode[] = episodes.data || [];
  const entry = media.mediaListEntry;

  const handleStatusChange = (status: string) => {
    updateMutation.mutate({ status });
  };

  const handlePlay = async (ep: Episode) => {
    try {
      const servers = await resolveStream(item.id, ep.number);
      const server = servers[0]?.url || "";
      setPlayback(media, ep, "gogoanime", server);
    } catch {
      // handled by error boundary
    }
  };

  const bannerSrc = media.bannerImage || media.coverImage?.large;

  return (
    <div className="absolute inset-y-0 right-0 w-[420px] bg-[var(--bg-glass)] backdrop-blur-xl border-l border-[var(--border)] shadow-2xl z-40 flex flex-col animate-slide-in">
      {/* Full-bleed banner header */}
      <div className="relative -mx-0 shrink-0 h-52 overflow-hidden">
        {bannerSrc && (
          <img
            src={bannerSrc}
            alt=""
            className="w-full h-full object-cover"
          />
        )}
        <div className="absolute inset-0 bg-gradient-to-t from-[var(--bg-secondary)] via-[var(--bg-secondary)]/30 to-transparent" />
        <div className="absolute top-3 right-3">
          <button
            onClick={closeDetail}
            className="w-7 h-7 rounded-full bg-black/40 backdrop-blur-sm flex items-center justify-center text-white/80 hover:text-white transition-colors"
          >
            <X size={14} />
          </button>
        </div>
        <div className="absolute bottom-3 left-3 flex items-end gap-3">
          {media.coverImage?.large && (
            <img
              src={media.coverImage.large}
              alt={title}
              className="w-14 h-20 object-cover rounded-lg shadow-lg ring-1 ring-white/10"
            />
          )}
          <div className="mb-1">
            <h3 className="font-bold text-white text-sm leading-tight drop-shadow-lg line-clamp-2">
              {title}
            </h3>
            {media.studios?.nodes?.[0] && (
              <p className="text-[11px] text-white/50">{media.studios.nodes[0].name}</p>
            )}
          </div>
        </div>
      </div>

      <div className="flex-1 overflow-y-auto px-4 pb-4 space-y-4">
        {/* Pill toggle group */}
        {!episodes.isLoading && (
          <div className="flex rounded-lg overflow-hidden border border-[var(--border)] text-sm">
            {([
              { status: "CURRENT", label: "Watching" },
              { status: "PLANNING", label: "Plan to Watch" },
              { status: "COMPLETED", label: "Completed" },
            ] as const).map(({ status, label }) => (
              <button
                key={status}
                onClick={() => handleStatusChange(status)}
                className={`flex-1 py-2 text-xs font-medium transition-colors ${
                  entry?.status === status
                    ? "bg-[var(--accent)] text-white"
                    : "bg-[var(--bg-tertiary)] text-[var(--text-secondary)] hover:text-[var(--text-primary)]"
                }`}
              >
                {label}
              </button>
            ))}
          </div>
        )}

        {/* Genres */}
        {media.genres && (
          <div className="flex gap-2 flex-wrap">
            {media.genres.map((g, i) => (
              <span
                key={g}
                className={`px-2 py-0.5 text-xs rounded-full border ${
                  i === 0
                    ? "border-[var(--accent)]/30 bg-[var(--accent-dim)] text-[var(--accent)]"
                    : "border-[var(--border-subtle)] bg-[var(--bg-tertiary)] text-[var(--text-secondary)]"
                }`}
              >
                {g}
              </span>
            ))}
          </div>
        )}

        {/* Stats grid */}
        <div className="grid grid-cols-2 gap-2 text-sm">
          {media.format && (
            <div>
              <span className="text-xs text-[var(--text-muted)]">Format</span>
              <p className="text-[var(--text-primary)] font-medium">{media.format}</p>
            </div>
          )}
          {media.status && (
            <div>
              <span className="text-xs text-[var(--text-muted)]">Status</span>
              <p className="text-[var(--text-primary)] font-medium">{media.status}</p>
            </div>
          )}
          {media.episodes && (
            <div>
              <span className="text-xs text-[var(--text-muted)]">Episodes</span>
              <p className="text-[var(--text-primary)] font-medium">{media.episodes}</p>
            </div>
          )}
          {media.averageScore && (
            <div>
              <span className="text-xs text-[var(--text-muted)]">Score</span>
              <p className="text-[var(--text-primary)] font-medium">{media.averageScore}%</p>
            </div>
          )}
          {media.season && (
            <div>
              <span className="text-xs text-[var(--text-muted)]">Season</span>
              <p className="text-[var(--text-primary)] font-medium">
                {media.season} {media.seasonYear}
              </p>
            </div>
          )}
          {media.duration && (
            <div>
              <span className="text-xs text-[var(--text-muted)]">Duration</span>
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
            <div className="space-y-1 max-h-96 overflow-y-auto">
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
                      className="w-14 h-14 rounded-full object-cover mx-auto ring-1 ring-white/10"
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
