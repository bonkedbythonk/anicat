import { Home, Search, Library, BookOpen, User } from "lucide-react";
import { useAppStore } from "@/stores/app";

export type PrimaryTab = "home" | "search" | "library" | "manga" | "you";

const navItems = [
  { label: "Home", tab: "home" as const, Icon: Home },
  { label: "Search", tab: "search" as const, Icon: Search },
  { label: "Library", tab: "library" as const, Icon: Library },
  { label: "Manga", tab: "manga" as const, Icon: BookOpen },
  { label: "You", tab: "you" as const, Icon: User },
];

interface BottomNavProps {
  activeTab: PrimaryTab;
  onTabChange: (tab: PrimaryTab) => void;
  /** Marks Home with a dot: something on the watching list airs soon. */
  hasSomethingNew?: boolean;
}

/** Ink & Index tab bar: icon over a mono-caps label, solid ink ground with a
 * hairline top border — glass/blur is banned by the skin. Active tab is the
 * single aizome accent. Purely prop-driven — mobile navigation state lives
 * in MobileApp, not the shared store's `currentView` that desktop's Sidebar
 * reads. */
export function BottomNav({ activeTab, onTabChange, hasSomethingNew = false }: BottomNavProps) {
  const selectedItem = useAppStore((s) => s.selectedItem);

  return (
    <nav
      className="fixed bottom-0 left-0 right-0 z-50 flex items-stretch justify-around border-t border-border bg-background"
      style={{ paddingBottom: "env(safe-area-inset-bottom)" }}
    >
      {navItems.map(({ label, tab, Icon }) => {
        const active = activeTab === tab && !selectedItem;
        return (
          <button
            key={tab}
            onClick={() => onTabChange(tab)}
            className={`flex-1 flex flex-col items-center gap-1 py-2.5 pb-4 font-mono text-[10px] uppercase tracking-[0.08em] transition-colors active:opacity-60 ${
              active ? "text-accent" : "text-muted-foreground"
            }`}
          >
            <span className="relative">
              <Icon size={20} strokeWidth={active ? 2.25 : 1.75} />
              {tab === "home" && hasSomethingNew && (
                <span className="absolute -right-[3px] -top-[1px] h-[6px] w-[6px] rounded-full bg-accent" />
              )}
            </span>
            {label}
          </button>
        );
      })}
    </nav>
  );
}
