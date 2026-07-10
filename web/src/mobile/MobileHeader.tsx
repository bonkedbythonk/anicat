import { ChevronLeft } from "lucide-react";

interface MobileHeaderProps {
  title: string;
  onBack?: () => void;
}

/** Compact iOS-style nav bar — fixed height and typography on every screen,
 * tab roots and More sub-views alike, with the Anicat mark always in the
 * left slot (swapped for a back chevron one level deep). Reused views
 * (Schedule, Notifications, Profile) still render their own large title
 * inside their own content; this bar is the persistent chrome above it, the
 * same relationship iOS itself uses between a nav bar and a large title. */
export function MobileHeader({ title, onBack }: MobileHeaderProps) {
  return (
    <header
      className="sticky top-0 z-40 flex items-center gap-2.5 border-b border-white/[0.06] bg-background/80 px-4 py-2.5 backdrop-blur-2xl"
      style={{ paddingTop: "calc(env(safe-area-inset-top) + 10px)" }}
    >
      {onBack ? (
        <button
          onClick={onBack}
          className="-ml-1.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-accent active:opacity-50"
        >
          <ChevronLeft size={22} />
        </button>
      ) : (
        <img src="/paw_icon.png" alt="" className="h-6 w-6 shrink-0" />
      )}
      <h1 className="truncate text-[17px] font-bold tracking-tight text-foreground">{title}</h1>
    </header>
  );
}
