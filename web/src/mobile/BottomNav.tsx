import { Home, Search, Bookmark, BookOpen, User } from "lucide-react";
import { useAppStore } from "@/stores/app";

export type PrimaryTab = "home" | "search" | "library" | "manga" | "you";

const navItems = [
  { icon: Home, label: "Home", tab: "home" as const },
  { icon: Search, label: "Search", tab: "search" as const },
  { icon: Bookmark, label: "Library", tab: "library" as const },
  { icon: BookOpen, label: "Manga", tab: "manga" as const },
  { icon: User, label: "You", tab: "you" as const },
];

interface BottomNavProps {
  activeTab: PrimaryTab;
  onTabChange: (tab: PrimaryTab) => void;
}

/** Deliberately its own styling rather than the desktop Sidebar's
 * `.glass-fixed` (that class was written for a vertical left rail — it ships
 * a `border-right` that makes no sense on a horizontal bottom bar, and no
 * safe-area awareness). Five tabs — the HIG ceiling — with Manga promoted to
 * first-class and profile/secondary sections folded into "You"; the old
 * "More" hub is gone. Purely prop-driven — mobile navigation state lives in
 * MobileApp, not the shared store's `currentView` that desktop's Sidebar
 * also reads. */
export function BottomNav({ activeTab, onTabChange }: BottomNavProps) {
  const selectedItem = useAppStore((s) => s.selectedItem);

  const tabClass = (active: boolean) =>
    `flex flex-1 flex-col items-center justify-center gap-1 py-2 active:scale-90 active:opacity-60 transition-transform duration-100 ${
      active ? "text-accent" : "text-muted-foreground"
    }`;

  return (
    <nav
      className="fixed bottom-0 left-0 right-0 z-50 flex items-stretch justify-around border-t border-white/[0.08] bg-[#0c0c0e]/80 backdrop-blur-2xl"
      style={{ paddingBottom: "env(safe-area-inset-bottom)" }}
    >
      {navItems.map((item) => {
        const Icon = item.icon;
        const active = activeTab === item.tab && !selectedItem;
        return (
          <button key={item.tab} onClick={() => onTabChange(item.tab)} className={tabClass(active)}>
            <Icon size={23} strokeWidth={active ? 2.5 : 2} />
            <span className="text-[10px] font-medium">{item.label}</span>
          </button>
        );
      })}
    </nav>
  );
}
