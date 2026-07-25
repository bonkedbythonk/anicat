import { useState, useEffect, useCallback } from "react";
import { useAppStore } from "@/stores/app";
import { Loader2, ChevronLeft, Play, Trash2, X } from "lucide-react";
import { listen } from "@tauri-apps/api/event";
import { mediaApi, type QueueItem } from "@/lib/api";
import { proxyImage } from "@/lib/proxy";

export function DownloadsView() {
  const [queue, setQueue] = useState<QueueItem[]>([]);
  const [loading, setLoading] = useState(true);
  const activeTab = useAppStore(s => s.downloadsTab);
  const setActiveTab = useAppStore(s => s.setDownloadsTab);
  const [selectedMediaId, setSelectedMediaId] = useState<number | null>(null);
  const [playingItem, setPlayingItem] = useState<{ mediaId: number; ep: number } | null>(null);

  const fetchQueue = useCallback(async () => {
    try {
      const data = await mediaApi.getQueue();
      setQueue(data);
    } catch {
      console.error("Failed to fetch queue");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchQueue();

    const unlistenPromise = listen<{ media_id: number; episode_number: number; progress: number }>(
      "download_progress",
      (event) => {
        const { media_id, episode_number, progress } = event.payload;
        setQueue((prev) =>
          prev.map((item) =>
            item.media_id === media_id && item.episode_number === episode_number
              ? { ...item, progress }
              : item
          )
        );
      }
    );

    let interval: ReturnType<typeof setInterval> | null = null;

    const hasActive = queue.some(
      (item) => item.status === "downloading" || item.status === "queued"
    );

    if (hasActive) {
      interval = setInterval(fetchQueue, 5000);
    }

    return () => {
      if (interval) clearInterval(interval);
      unlistenPromise.then((fn) => fn());
    };
  }, [fetchQueue, queue]);

  const handleRetry = async () => {
    setQueue(prev =>
      prev.map(item =>
        item.status === "failed" ? { ...item, status: "queued" } : item
      )
    );
    try {
      await mediaApi.retryQueue();
      fetchQueue();
    } catch (err) {
      console.error("Failed to retry queue:", err);
      fetchQueue();
    }
  };

  const handleRemove = async (mediaId: number, ep: number) => {
    setQueue(prev =>
      prev.filter(item => !(item.media_id === mediaId && item.episode_number === ep))
    );
    try {
      await mediaApi.removeFromQueue(mediaId, ep);
      fetchQueue();
    } catch (err) {
      console.error("Failed to remove item:", err);
      fetchQueue();
    }
  };

  const handlePlay = async (mediaId: number, ep: number) => {
    setPlayingItem({ mediaId, ep });
    try {
      await mediaApi.play(mediaId, ep);
    } catch (error) {
      console.error("Failed to play:", error);
    } finally {
      setPlayingItem(null);
    }
  };

  // Status rendered as a small dot + mono word — semantic color, no chips.
  const statusMeta = (item: QueueItem) => {
    switch (item.status) {
      case "downloading":
        return { dot: "bg-accent", label: `Downloading ${Math.round(item.progress || 0)}%`, cls: "text-accent" };
      case "queued":
        return { dot: "bg-foreground/30", label: "Queued", cls: "text-muted-foreground" };
      case "failed":
        return { dot: "bg-red-400/80", label: "Failed", cls: "text-red-400/90" };
      default:
        return { dot: "bg-foreground/30", label: item.status, cls: "text-muted-foreground" };
    }
  };

  const completedGroups = queue
    .filter((item) => item.status === "completed")
    .reduce((groups: Record<number, { title: string; cover?: string; episodes: QueueItem[] }>, item) => {
      if (!groups[item.media_id]) {
        groups[item.media_id] = {
          title: item.media_title,
          cover: item.cover_image,
          episodes: [],
        };
      }
      groups[item.media_id].episodes.push(item);
      return groups;
    }, {});

  Object.values(completedGroups).forEach((group) => {
    group.episodes.sort((a, b) => {
      const numA = a.episode_number;
      const numB = b.episode_number;
      return (isNaN(numA) ? 0 : numA) - (isNaN(numB) ? 0 : numB);
    });
  });

  const activeQueue = queue.filter((item) => item.status !== "completed");
  const selectedMedia = selectedMediaId !== null ? completedGroups[selectedMediaId] : null;
  const failedCount = activeQueue.filter((i) => i.status === "failed").length;

  return (
    <div className="space-y-5 pb-12 max-w-[1100px]">
      <div className="flex items-end justify-between gap-4 flex-wrap">
        <div>
          <h1 className="text-[19px] font-semibold tracking-tight text-foreground">Downloads</h1>
          <p className="meta-mono mt-1 text-muted-foreground">
            {Object.keys(completedGroups).length} shows offline · {activeQueue.length} in queue
          </p>
        </div>
        {activeTab === "queue" && failedCount > 0 && (
          <button
            onClick={handleRetry}
            className="rounded-md border border-border px-3.5 py-1.5 text-[12px] font-medium text-foreground/70 hover:text-foreground hover:border-foreground/25 cursor-pointer"
          >
            Retry {failedCount} failed
          </button>
        )}
      </div>

      <div className="flex gap-1">
        {([
          { key: "library" as const, label: "Offline library" },
          { key: "queue" as const, label: "Queue" },
        ]).map((tab) => (
          <button
            key={tab.key}
            onClick={() => { setActiveTab(tab.key); setSelectedMediaId(null); }}
            className={`px-3 py-1.5 rounded-md text-[12.5px] font-medium cursor-pointer ${
              activeTab === tab.key ? "bg-accent/15 text-accent" : "text-foreground/50 hover:text-foreground/80"
            }`}
          >
            {tab.label}
          </button>
        ))}
      </div>

      {loading ? (
        <div className="flex items-center justify-center py-24">
          <Loader2 className="animate-spin text-accent" size={28} />
        </div>
      ) : activeTab === "library" ? (
        selectedMedia ? (
          <div className="space-y-4 animate-fade-in">
            <button
              onClick={() => setSelectedMediaId(null)}
              className="flex items-center gap-1.5 text-[12.5px] font-medium text-foreground/60 hover:text-foreground cursor-pointer"
            >
              <ChevronLeft size={14} />
              All downloads
            </button>
            <div className="flex items-center gap-4">
              {selectedMedia.cover && (
                <img src={proxyImage(selectedMedia.cover)} alt="" className="w-12 h-16 rounded object-cover" />
              )}
              <div>
                <h2 className="text-[16px] font-semibold text-foreground leading-tight">{selectedMedia.title}</h2>
                <p className="meta-mono mt-1 text-muted-foreground">
                  {selectedMedia.episodes.length} episode{selectedMedia.episodes.length === 1 ? "" : "s"} on disk
                </p>
              </div>
            </div>
            <div className="rounded-lg border border-border overflow-hidden">
              {selectedMedia.episodes.map((ep) => {
                const isCurrentPlaying = playingItem?.mediaId === ep.media_id && playingItem?.ep === ep.episode_number;
                return (
                  <div
                    key={ep.episode_number}
                    className="flex items-center justify-between gap-4 px-4 py-2.5 border-b border-border last:border-b-0 hover:bg-surface/70"
                  >
                    <span className="meta-mono text-foreground/80">EP {ep.episode_number} · Offline</span>
                    <div className="flex items-center gap-2">
                      <button
                        onClick={() => handlePlay(ep.media_id, ep.episode_number)}
                        disabled={playingItem !== null}
                        className="flex items-center gap-1.5 rounded-md bg-accent px-3.5 py-1.5 text-[12px] font-semibold text-black hover:bg-accent-light disabled:opacity-50 cursor-pointer"
                      >
                        {isCurrentPlaying ? <Loader2 size={11} className="animate-spin" /> : <Play size={11} fill="currentColor" />}
                        Play
                      </button>
                      <button
                        onClick={() => {
                          handleRemove(ep.media_id, ep.episode_number);
                          if (selectedMedia.episodes.length <= 1) setSelectedMediaId(null);
                        }}
                        className="p-1.5 rounded-md border border-border text-muted-foreground hover:text-red-400/90 hover:border-red-400/30 cursor-pointer"
                        title="Delete from disk"
                      >
                        <Trash2 size={13} />
                      </button>
                    </div>
                  </div>
                );
              })}
            </div>
          </div>
        ) : Object.keys(completedGroups).length > 0 ? (
          <div className="rounded-lg border border-border overflow-hidden animate-fade-in">
            {Object.entries(completedGroups).map(([mediaIdStr, group]) => {
              const mediaId = parseInt(mediaIdStr);
              return (
                <button
                  key={mediaId}
                  onClick={() => setSelectedMediaId(mediaId)}
                  className="w-full flex items-center gap-4 px-4 py-3 border-b border-border last:border-b-0 text-left hover:bg-surface/70 cursor-pointer"
                >
                  {group.cover ? (
                    <img src={proxyImage(group.cover)} alt="" className="w-9 h-12 rounded object-cover shrink-0" />
                  ) : (
                    <div className="w-9 h-12 rounded bg-surface border border-border shrink-0" />
                  )}
                  <span className="flex-1 min-w-0 truncate text-[13.5px] font-medium text-foreground">{group.title}</span>
                  <span className="meta-mono text-muted-foreground shrink-0">
                    {group.episodes.length} EP offline
                  </span>
                </button>
              );
            })}
          </div>
        ) : (
          <div className="py-20 text-center rounded-lg border border-dashed border-border">
            <p className="meta-mono text-muted-foreground">Nothing downloaded yet</p>
            <p className="text-sm text-foreground/50 mt-2">Download episodes from a show's episode list and they appear here.</p>
          </div>
        )
      ) : activeQueue.length > 0 ? (
        <div className="rounded-lg border border-border overflow-hidden animate-fade-in">
          {activeQueue.map((item, idx) => {
            const status = statusMeta(item);
            return (
              <div
                key={`${item.media_id}-${item.episode_number}-${idx}`}
                className="relative px-4 py-3 border-b border-border last:border-b-0"
              >
                <div className="flex items-center justify-between gap-4">
                  <div className="min-w-0">
                    <p className="truncate text-[13.5px] font-medium text-foreground">{item.media_title}</p>
                    <p className="meta-mono mt-1 flex items-center gap-2.5">
                      <span className="text-muted-foreground">EP {item.episode_number}</span>
                      <span className="flex items-center gap-1.5">
                        <span className={`inline-block w-1.5 h-1.5 rounded-full ${status.dot}`} />
                        <span className={status.cls}>{status.label}</span>
                      </span>
                    </p>
                    {item.status === "failed" && item.error_message && (
                      <p className="mt-1 text-[11.5px] text-red-400/70 truncate max-w-[520px]" title={item.error_message}>
                        {item.error_message}
                      </p>
                    )}
                  </div>
                  <button
                    onClick={() => handleRemove(item.media_id, item.episode_number)}
                    className="p-1.5 rounded-md border border-border text-muted-foreground hover:text-red-400/90 hover:border-red-400/30 cursor-pointer shrink-0"
                    title="Remove"
                  >
                    <X size={13} />
                  </button>
                </div>
                {item.status === "downloading" && (
                  <div className="absolute bottom-0 left-0 right-0 h-[2px] bg-foreground/5">
                    <div
                      className="h-full bg-accent transition-all duration-300 ease-out"
                      style={{ width: `${item.progress || 0}%` }}
                    />
                  </div>
                )}
              </div>
            );
          })}
        </div>
      ) : (
        <div className="py-20 text-center rounded-lg border border-dashed border-border">
          <p className="meta-mono text-muted-foreground">Queue is empty</p>
          <p className="text-sm text-foreground/50 mt-2">No downloads running, queued, or failed right now.</p>
        </div>
      )}
    </div>
  );
}
