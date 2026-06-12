import type { MediaItem } from "@/lib/types";
import { proxyImage } from "@/lib/proxy";
export function LazyCard({ item, onSelect }: { item: MediaItem; onSelect: (item: MediaItem) => void }) {
  return <button onClick={() => onSelect(item)} className="aspect-[2/3] rounded-lg overflow-hidden bg-surface">
    {item.cover_image?.large && <img src={proxyImage(item.cover_image.large)} className="w-full h-full object-cover" loading="lazy" alt="" />}
  </button>;
}
