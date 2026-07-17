import { PosterCard } from "./PosterCard";
import type { MediaItem } from "@/lib/types";

interface PosterRowProps {
  title: string;
  items: MediaItem[];
  onSelect: (item: MediaItem) => void;
}

export function PosterRow({ title, items, onSelect }: PosterRowProps) {
  if (items.length === 0) return null;
  return (
    <div className="space-y-2.5">
      <div className="flex items-baseline justify-between">
        <h2 className="text-[15px] font-semibold tracking-tight text-foreground">{title}</h2>
        <span className="font-mono text-[10px] uppercase tracking-[0.08em] text-muted-foreground tabular-nums">{items.length}</span>
      </div>
      <div className="-mx-6 flex gap-3 overflow-x-auto px-6 pb-1 scrollbar-hide">
        {items.map((item) => (
          <PosterCard key={item.id} item={item} onSelect={onSelect} />
        ))}
      </div>
    </div>
  );
}
