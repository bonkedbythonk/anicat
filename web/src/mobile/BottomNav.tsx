import { useAppStore } from "@/stores/app";

export type PrimaryTab = "home" | "search" | "library" | "manga" | "you";

const navItems = [
  { label: "Home", tab: "home" as const },
  { label: "Search", tab: "search" as const },
  { label: "Library", tab: "library" as const },
  { label: "Manga", tab: "manga" as const },
  { label: "You", tab: "you" as const },
];

interface BottomNavProps {
  activeTab: PrimaryTab;
  onTabChange: (tab: PrimaryTab) => void;
}

/** Ink & Index tab bar: plain words in mono caps, no icons (nothing to
 * decode), solid ink ground with a hairline top border — glass/blur is
 * banned by the skin. Active tab is the single aizome accent. Purely
 * prop-driven — mobile navigation state lives in MobileApp, not the shared
 * store's `currentView` that desktop's Sidebar reads. */
export function BottomNav({ activeTab, onTabChange }: BottomNavProps) {
  const selectedItem = useAppStore((s) => s.selectedItem);

  return (
    <nav
      className="fixed bottom-0 left-0 right-0 z-50 flex items-stretch justify-around border-t border-border bg-background"
      style={{ paddingBottom: "env(safe-area-inset-bottom)" }}
    >
      {navItems.map((item) => {
        const active = activeTab === item.tab && !selectedItem;
        return (
          <button
            key={item.tab}
            onClick={() => onTabChange(item.tab)}
            className={`flex-1 py-3.5 pb-4 text-center font-mono text-[10px] uppercase tracking-[0.08em] transition-colors active:opacity-60 ${
              active ? "text-accent" : "text-muted-foreground"
            }`}
          >
            {item.label}
          </button>
        );
      })}
    </nav>
  );
}
