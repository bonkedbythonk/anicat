import { useState, memo } from "react";
import type { MediaItem } from "@/lib/types";
import { proxyImage } from "@/lib/proxy";

const LazyCard = memo(function LazyCard({ item, onSelect }: { item: MediaItem; onSelect: (item: MediaItem) => void }) {
  const [loaded, setLoaded] = useState(false);
  const src = item.cover_image?.large;

  return (
    <button onClick={() => onSelect(item)} className="aspect-[2/3] rounded-lg overflow-hidden bg-surface relative">
      {src && (
        <img 
          src={proxyImage(src)} 
          className={`w-full h-full object-cover transition-opacity duration-300 ${
            loaded ? "opacity-100" : "opacity-0"
          }`} 
          loading="lazy" 
          onLoad={() => setLoaded(true)}
          alt="" 
        />
      )}
    </button>
  );
});

export { LazyCard };
