import type { MediaItem } from "@/lib/types";
export function LazyCard({ item, onSelect }: { item: MediaItem; onSelect: (item: MediaItem) => void }) {
  return <button onClick={() => onSelect(item)} className="aspect-[2/3] rounded-lg overflow-hidden bg-surface">
    {item.cover_image?.large && <img src={item.cover_image.large} className="w-full h-full object-cover" loading="lazy" />}
  </button>;
}
