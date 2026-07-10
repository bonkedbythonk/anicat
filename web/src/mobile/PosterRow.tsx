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
      <h2 className="text-[17px] font-bold text-foreground">{title}</h2>
      <div className="-mx-6 flex gap-2.5 overflow-x-auto px-6 pb-1 scrollbar-hide">
        {items.map((item) => (
          <PosterCard key={item.id} item={item} onSelect={onSelect} />
        ))}
      </div>
    </div>
  );
}
