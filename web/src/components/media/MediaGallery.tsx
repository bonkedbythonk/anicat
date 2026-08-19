import { useEffect, useMemo, useState } from "react";
import { X, ChevronLeft, ChevronRight, Eye } from "lucide-react";
import { proxyImage } from "@/lib/proxy";
import type { AniZipMeta } from "@/lib/api";
import { useModalDismiss } from "@/hooks/useModalDismiss";
import { FocusScope, ScopeNav, useFocusable } from "@/focus";

export interface GalleryImage {
  url: string;
  /** Caption under the tile, e.g. "Episode 3" or "Key Art" */
  label: string;
  /** Set for per-episode stills; absent for series artwork */
  episode?: number;
}

/**
 * Series artwork first (never a spoiler), then episode stills in number
 * order. Shared by the desktop and mobile detail pages.
 */
export function buildGalleryImages(
  anizip: AniZipMeta | undefined,
  bannerImage: string | undefined,
  episodeThumbMap: Record<number, string>,
): GalleryImage[] {
  const seen = new Set<string>();
  const out: GalleryImage[] = [];
  const push = (url: string | undefined, label: string, episode?: number) => {
    if (!url || seen.has(url)) return;
    seen.add(url);
    out.push({ url, label, episode });
  };

  (anizip?.artwork.fanart ?? []).forEach((url, i) => push(url, `Key Art ${i + 1}`));
  (anizip?.artwork.banner ?? []).forEach((url, i) => push(url, `Banner ${i + 1}`));

  const stills = Object.entries(episodeThumbMap)
    .map(([num, url]) => [Number(num), url] as const)
    .sort((a, b) => a[0] - b[0]);
  // A movie has one "episode"; numbering its single frame reads wrong.
  const stillLabel = (num: number) => (stills.length <= 1 ? "Still" : `Episode ${num}`);
  stills.forEach(([num, url]) => push(url, stillLabel(num), num));

  // The hero banner is already on screen right above the strip, so it only
  // earns a tile when nothing else came back.
  if (out.length === 0) push(bannerImage, "Banner");

  return out;
}

interface MediaGalleryProps {
  images: GalleryImage[];
  /**
   * How many episode stills to show before the "Show all" reveal. Stills past
   * the viewer's progress are frames they have not watched yet, so they stay
   * behind the reveal rather than spoiling the finale in a glance strip.
   * Series artwork is never capped — it cannot spoil anything.
   */
  stillsAllowed?: number;
}

function GalleryTile({
  image,
  onOpen,
  onBroken,
}: {
  image: GalleryImage;
  onOpen: () => void;
  onBroken: () => void;
}) {
  const { ref, tabIndex } = useFocusable<HTMLButtonElement>();
  return (
    <button
      ref={ref}
      tabIndex={tabIndex}
      onClick={onOpen}
      aria-label={`View ${image.label} full size`}
      className="group shrink-0 w-[168px] text-left rounded-md overflow-hidden border border-border bg-foreground/[0.02] hover:border-accent/40 transition-all active:scale-[0.98]"
    >
      <div className="relative w-full aspect-video overflow-hidden bg-foreground/5">
        <img
          src={proxyImage(image.url)}
          alt={image.label}
          loading="lazy"
          onError={onBroken}
          className="w-full h-full object-cover transition-transform duration-300 group-hover:scale-105"
        />
      </div>
      <div className="px-2.5 py-1.5 text-[10px] font-bold text-muted-foreground truncate group-hover:text-foreground transition-colors">
        {image.label}
      </div>
    </button>
  );
}

function Lightbox({
  images,
  index,
  onClose,
  onIndexChange,
}: {
  images: GalleryImage[];
  index: number;
  onClose: () => void;
  onIndexChange: (next: number) => void;
}) {
  // Restores focus to the tile that opened the lightbox on unmount.
  const dialogRef = useModalDismiss<HTMLDivElement>(true, onClose);
  const current = images[index];

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === "ArrowRight") {
        e.preventDefault();
        onIndexChange((index + 1) % images.length);
      } else if (e.key === "ArrowLeft") {
        e.preventDefault();
        onIndexChange((index - 1 + images.length) % images.length);
      }
    };
    document.addEventListener("keydown", onKeyDown, true);
    return () => document.removeEventListener("keydown", onKeyDown, true);
  }, [index, images.length, onIndexChange]);

  if (!current) return null;

  return (
    <div
      ref={dialogRef}
      role="dialog"
      aria-modal="true"
      aria-label={current.label}
      tabIndex={-1}
      className="fixed inset-0 z-[100] flex items-center justify-center bg-black/90 backdrop-blur-sm p-6 animate-fade-in"
      onClick={onClose}
    >
      <button
        onClick={onClose}
        aria-label="Close image viewer"
        className="absolute top-5 right-5 p-2.5 rounded-md bg-foreground/10 text-foreground hover:bg-foreground/20 transition-all"
      >
        <X size={20} />
      </button>

      {images.length > 1 && (
        <button
          onClick={(e) => {
            e.stopPropagation();
            onIndexChange((index - 1 + images.length) % images.length);
          }}
          aria-label="Previous image"
          className="absolute left-4 p-3 rounded-md bg-foreground/10 text-foreground hover:bg-foreground/20 transition-all"
        >
          <ChevronLeft size={22} />
        </button>
      )}

      <figure className="max-w-5xl w-full flex flex-col items-center gap-3" onClick={(e) => e.stopPropagation()}>
        <img
          src={proxyImage(current.url)}
          alt={current.label}
          className="max-h-[78vh] w-auto max-w-full rounded-md object-contain shadow-2xl"
        />
        <figcaption className="text-xs font-bold text-foreground/70">
          {current.label}
          <span className="ml-2 text-muted-foreground font-medium">
            {index + 1} / {images.length}
          </span>
        </figcaption>
      </figure>

      {images.length > 1 && (
        <button
          onClick={(e) => {
            e.stopPropagation();
            onIndexChange((index + 1) % images.length);
          }}
          aria-label="Next image"
          className="absolute right-4 p-3 rounded-md bg-foreground/10 text-foreground hover:bg-foreground/20 transition-all"
        >
          <ChevronRight size={22} />
        </button>
      )}
    </div>
  );
}

/**
 * Horizontal strip of stills and key art, so the art style is readable at a
 * glance without starting the show or sitting through the trailer.
 */
export function MediaGallery({ images, stillsAllowed }: MediaGalleryProps) {
  const [brokenUrls, setBrokenUrls] = useState<Set<string>>(new Set());
  const [revealAll, setRevealAll] = useState(false);
  const [lightboxIndex, setLightboxIndex] = useState<number | null>(null);

  // TVDB and Crunchyroll URLs go stale; a tile that failed to load is dropped
  // rather than left as a broken-image box.
  const usable = useMemo(() => images.filter((img) => !brokenUrls.has(img.url)), [images, brokenUrls]);

  // Counted over `usable`, not `images`: a broken artwork URL must not push an
  // unwatched still past the cap.
  const visible = useMemo(() => {
    if (revealAll || stillsAllowed === undefined) return usable;
    let stills = 0;
    return usable.filter((img) => {
      if (img.episode === undefined) return true;
      stills += 1;
      return stills <= stillsAllowed;
    });
  }, [usable, revealAll, stillsAllowed]);

  const hiddenCount = usable.length - visible.length;

  if (usable.length === 0) return null;

  return (
    <div className="space-y-3">
      <div className="flex items-center justify-between">
        <h3 className="meta-mono text-accent">Stills</h3>
        {hiddenCount > 0 && (
          <button
            onClick={() => setRevealAll(true)}
            className="flex items-center gap-1.5 text-[11px] font-bold text-foreground/50 hover:text-foreground transition-colors"
          >
            <Eye size={12} />
            <span>Show {hiddenCount} more (may spoil)</span>
          </button>
        )}
      </div>

      <FocusScope name="detail-gallery" orientation="horizontal" className="flex gap-3 overflow-x-auto pb-2 -mx-1 px-1">
        <ScopeNav />
        {visible.map((img) => (
          <GalleryTile
            key={img.url}
            image={img}
            onOpen={() => setLightboxIndex(visible.indexOf(img))}
            onBroken={() => setBrokenUrls((prev) => new Set(prev).add(img.url))}
          />
        ))}
      </FocusScope>

      {lightboxIndex !== null && (
        <Lightbox
          images={visible}
          index={Math.min(lightboxIndex, visible.length - 1)}
          onClose={() => setLightboxIndex(null)}
          onIndexChange={setLightboxIndex}
        />
      )}
    </div>
  );
}
