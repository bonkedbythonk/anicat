import { Home, Search, Monitor, MoreHorizontal } from "lucide-react";
import { useAppStore } from "@/stores/app";

const navItems = [
  { icon: Home, label: "Home", tab: "home" as const },
  { icon: Search, label: "Search", tab: "search" as const },
  { icon: Monitor, label: "Lists", tab: "lists" as const },
];

type PrimaryTab = "home" | "search" | "lists";

interface BottomNavProps {
  activeTab: PrimaryTab | null;
  moreActive: boolean;
  onTabChange: (tab: PrimaryTab) => void;
  onMoreTap: () => void;
}

/** Deliberately its own styling rather than the desktop Sidebar's
 * `.glass-fixed` (that class was written for a vertical left rail — it ships
 * a `border-right` that makes no sense on a horizontal bottom bar, and no
 * safe-area awareness). Capped at 4 tabs (Home/Search/Lists/More) rather
 * than mirroring every desktop nav item 1:1 — Apple's HIG caps tab bars at
 * ~5 for a reason, and beyond that labels truncate on a real phone width.
 * Schedule/Manga/Notifications/Profile live inside the More hub instead.
 * Purely prop-driven — mobile navigation state lives in MobileApp, not the
 * shared store's `currentView` that desktop's Sidebar also reads. */
export function BottomNav({ activeTab, moreActive, onTabChange, onMoreTap }: BottomNavProps) {
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
      <button onClick={onMoreTap} className={tabClass(moreActive && !selectedItem)}>
        <MoreHorizontal size={23} strokeWidth={moreActive ? 2.5 : 2} />
        <span className="text-[10px] font-medium">More</span>
      </button>
    </nav>
  );
}
