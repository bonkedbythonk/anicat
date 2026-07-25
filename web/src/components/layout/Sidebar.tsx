import { useAppStore } from "@/stores/app";
import { usesOverlayTitlebar, isMacOS } from "@/lib/platform";
import { useFocusable, FocusScope, ScopeNav } from "@/focus";
import type { ViewType } from "@/lib/types";

interface NavItem {
  label: string;
  view: ViewType;
  shortcut?: string;
}

const libraryItems: NavItem[] = [
  { label: "Up Next", view: "home", shortcut: "H" },
  { label: "Schedule", view: "schedule" },
  { label: "Library", view: "lists", shortcut: "L" },
  { label: "Manga", view: "manga", shortcut: "M" },
  { label: "Search", view: "search" },
  { label: "History", view: "profile" },
];

const systemItems: NavItem[] = [
  { label: "Downloads", view: "downloads", shortcut: "D" },
  { label: "Settings", view: "settings" },
];

function FocusableNavItem({
  item,
  isActive,
  onClick,
}: {
  item: NavItem;
  isActive: boolean;
  onClick: () => void;
}) {
  const { ref, tabIndex } = useFocusable<HTMLButtonElement>();
  return (
    <button
      ref={ref}
      tabIndex={tabIndex}
      onClick={onClick}
      aria-current={isActive ? "page" : undefined}
      className={`group relative w-full flex items-center justify-between py-[7px] pl-5 pr-4 text-[13px] cursor-pointer text-left ${
        isActive
          ? "text-foreground bg-accent/10 shadow-[inset_2px_0_0_var(--accent-color)] font-semibold"
          : "text-foreground/55 hover:text-foreground/85"
      }`}
    >
      <span>{item.label}</span>
      {item.shortcut && (
        <kbd
          aria-hidden="true"
          className="meta-mono hidden group-hover:inline-block text-[9px] px-1.5 py-0.5 rounded bg-foreground/[0.06] text-muted-foreground border border-border/50"
        >
          {item.shortcut}
        </kbd>
      )}
    </button>
  );
}

function NavGroup({ title, items }: { title: string; items: NavItem[] }) {
  const currentView = useAppStore((s) => s.currentView);
  const setCurrentView = useAppStore((s) => s.setCurrentView);
  const selectedItem = useAppStore((s) => s.selectedItem);
  const closeDetail = useAppStore((s) => s.closeDetail);

  const handleNavigate = (view: ViewType) => {
    if (selectedItem) closeDetail();
    setCurrentView(view);
  };

  return (
    <div>
      <div className="meta-mono px-5 pb-1.5 pt-4 text-muted-foreground/70 select-none">{title}</div>
      {items.map((item) => (
        <FocusableNavItem
          key={item.view}
          item={item}
          isActive={currentView === item.view}
          onClick={() => handleNavigate(item.view)}
        />
      ))}
    </div>
  );
}

export function Sidebar() {
  const setPaletteOpen = useAppStore((s) => s.setPaletteOpen);
  const apiConnected = useAppStore((s) => s.apiConnected);
  const apiAuthenticated = useAppStore((s) => s.apiAuthenticated);
  const isOffline = useAppStore((s) => s.isOffline);
  const { ref, tabIndex } = useFocusable<HTMLButtonElement>();

  const syncLabel = isOffline
    ? "Offline"
    : apiConnected && apiAuthenticated
      ? "Synced with AniList"
      : apiConnected
        ? "Not signed in"
        : "Connecting";

  return (
    <FocusScope as="aside" name="sidebar" orientation="vertical" className="fixed left-0 top-0 bottom-0 z-50 flex flex-col glass-fixed" style={{ width: 200 }}>
      <ScopeNav />
      <div
        data-tauri-drag-region
        className={`w-full cursor-default select-none ${usesOverlayTitlebar ? "h-[38px]" : "h-4"} shrink-0`}
      />

      <nav className="flex-1 overflow-y-auto scrollbar-hide pb-2">
        <NavGroup title="Library" items={libraryItems} />
        <NavGroup title="System" items={systemItems} />
      </nav>

      <div className="px-4 pb-4 space-y-3">
        <div className="flex justify-center pb-2 opacity-10 pointer-events-none select-none mix-blend-luminosity">
          <img src="/anicat_logo.png" alt="Anicat Logo" className="h-20 object-contain filter grayscale" />
        </div>
        <button
          ref={ref}
          tabIndex={tabIndex}
          onClick={() => setPaletteOpen(true)}
          className="w-full flex items-center justify-between px-3 py-2 rounded-md border border-border text-[12px] text-foreground/45 hover:text-foreground/75 hover:border-foreground/25 cursor-pointer"
        >
          <span>Search anything</span>
          <kbd className="meta-mono text-[9px] text-muted-foreground">{isMacOS ? "⌘K" : "Ctrl K"}</kbd>
        </button>
      </div>
    </FocusScope>
  );
}
