import { ChevronLeft } from "lucide-react";

interface MobileHeaderProps {
  title: string;
  onBack?: () => void;
}

/** Compact nav bar in the Ink & Index idiom — solid ink ground, hairline
 * bottom border, no blur. The wordmark slot is a small mono label (swapped
 * for a back chevron one level deep). Reused views (Schedule, Profile)
 * still render their own large title inside their own content; this bar is
 * the persistent chrome above it. */
export function MobileHeader({ title, onBack }: MobileHeaderProps) {
  return (
    <header
      className="sticky top-0 z-40 flex items-baseline gap-2.5 border-b border-border bg-background px-5 py-3"
      style={{ paddingTop: "calc(env(safe-area-inset-top) + 12px)" }}
    >
      {onBack ? (
        <button
          onClick={onBack}
          className="-ml-1.5 flex h-6 w-6 shrink-0 items-center justify-center self-center text-accent active:opacity-50"
        >
          <ChevronLeft size={20} />
        </button>
      ) : (
        <span className="font-mono text-[10px] uppercase tracking-[0.1em] text-muted-foreground">Anicat</span>
      )}
      <h1 className="truncate text-[17px] font-bold tracking-tight text-foreground">{title}</h1>
    </header>
  );
}
