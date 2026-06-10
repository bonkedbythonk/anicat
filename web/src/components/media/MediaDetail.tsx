import { useAppStore } from "@/stores/app";
import type { MediaItem } from "@/lib/types";
import { X } from "lucide-react";

export function MediaDetail({ item }: { item: MediaItem }) {
  const closeDetail = useAppStore((s) => s.closeDetail);
  const title = item.title.romaji || item.title.english || "Unknown";
  return (
    <div className="absolute inset-y-0 right-0 w-[420px] bg-[var(--bg-secondary)] border-l border-[var(--border)] shadow-2xl z-40 flex flex-col animate-slide-in">
      <div className="flex items-center justify-between p-4 border-b border-[var(--border)]">
        <h3 className="font-medium text-[var(--text-primary)] truncate pr-4">{title}</h3>
        <button onClick={closeDetail} className="text-[var(--text-muted)] hover:text-[var(--text-primary)]"><X size={18} /></button>
      </div>
      <div className="flex-1 overflow-y-auto p-4 space-y-4">
        {item.coverImage?.large && <img src={item.coverImage.large} alt={title} className="w-full rounded-lg" />}
        <div className="space-y-2">
          <div className="flex gap-2 flex-wrap">
            {item.genres?.map((g) => (
              <span key={g} className="px-2 py-0.5 text-xs rounded-full bg-[var(--bg-tertiary)] text-[var(--text-secondary)]">{g}</span>
            ))}
          </div>
          {item.description && (
            <p className="text-sm text-[var(--text-secondary)] leading-relaxed" dangerouslySetInnerHTML={{ __html: item.description }} />
          )}
          <div className="grid grid-cols-2 gap-2 text-sm">
            {item.format && <div><span className="text-[var(--text-muted)]">Format</span><p className="text-[var(--text-primary)]">{item.format}</p></div>}
            {item.status && <div><span className="text-[var(--text-muted)]">Status</span><p className="text-[var(--text-primary)]">{item.status}</p></div>}
            {item.episodes && <div><span className="text-[var(--text-muted)]">Episodes</span><p className="text-[var(--text-primary)]">{item.episodes}</p></div>}
            {item.averageScore && <div><span className="text-[var(--text-muted)]">Score</span><p className="text-[var(--text-primary)]">{item.averageScore}%</p></div>}
          </div>
        </div>
      </div>
    </div>
  );
}
