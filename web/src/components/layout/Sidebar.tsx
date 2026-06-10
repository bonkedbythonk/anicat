import { useAppStore } from "@/stores/app";
import {
  Home,
  Search,
  Download,
  Library,
  Settings,
  Monitor,
  Bell,
  User,
  Calendar,
} from "lucide-react";

const navItems = [
  { icon: Home, label: "Home", view: "home" as const, shortcut: "H" },
  { icon: Search, label: "Search", view: "search" as const, shortcut: "/" },
  { icon: Monitor, label: "My Lists", view: "lists" as const, shortcut: "L" },
  { icon: Download, label: "Downloads", view: "downloads" as const, shortcut: "D" },
  { icon: Library, label: "Library", view: "library" as const },
  { icon: Calendar, label: "Schedule", view: "schedule" as const },
];

const secondaryItems = [
  { icon: Bell, label: "Notifications", view: "notifications" as const, shortcut: "N" },
  { icon: User, label: "Profile", view: "profile" as const },
  { icon: Settings, label: "Settings", view: "settings" as const },
];

export function Sidebar() {
  const currentView = useAppStore((s) => s.currentView);
  const setCurrentView = useAppStore((s) => s.setCurrentView);
  const selectedItem = useAppStore((s) => s.selectedItem);
  const closeDetail = useAppStore((s) => s.closeDetail);

  const handleNavigate = (view: typeof currentView) => {
    if (selectedItem) closeDetail();
    setCurrentView(view);
  };

  return (
    <aside className="fixed left-0 top-0 bottom-0 w-[72px] lg:w-[248px] z-50 flex flex-col py-6 transition-all duration-300 glass-fixed">
      <div
        data-tauri-drag-region
        className="flex flex-col items-center justify-center px-4 lg:px-6 mb-10 pt-14 cursor-default select-none w-full"
      >
        <img
          src="/anicat_logo.png"
          alt="Anicat Logo"
          className="w-24 h-auto lg:w-32 opacity-95 hover:opacity-100 transition-opacity object-contain pointer-events-none anicat-logo"
        />
        {import.meta.env.DEV && (
          <span className="mt-1.5 px-2 py-0.5 text-[9px] font-black uppercase tracking-widest bg-purple-500/10 text-purple-400 border border-purple-500/25 rounded-md select-none font-mono pointer-events-none">
            Local Dev
          </span>
        )}
      </div>

      <nav className="flex-1 space-y-1 px-3 lg:px-6 pt-2 overflow-y-auto scrollbar-hide">
        {navItems.map((item) => {
          const isActive = currentView === item.view;
          return (
            <button
              key={item.view}
              onClick={() => handleNavigate(item.view)}
              className={`w-full flex items-center justify-center lg:justify-start lg:space-x-3 px-3 py-2.5 rounded-xl transition-all duration-200 group border cursor-pointer ${
                isActive
                  ? "bg-gradient-to-r from-accent/15 to-accent-light/10 border-accent/15 shadow-[0_0_15px_rgba(0,0,0,0.15)] shadow-accent/10 text-accent font-bold"
                  : "text-gray-500 dark:text-gray-400 hover:text-foreground hover:bg-foreground/[0.04] border-transparent"
              }`}
            >
              <item.icon
                size={20}
                className={`shrink-0 transition-colors ${
                  isActive
                    ? "text-accent"
                    : "text-gray-500 dark:text-gray-400 group-hover:text-accent"
                }`}
              />
              <span className="hidden lg:flex items-center justify-between flex-1 text-[13px] font-semibold tracking-wide">
                <span>{item.label}</span>
                {item.shortcut && (
                  <kbd className="ml-auto text-[9px] font-mono font-bold px-1.5 py-0.5 rounded-md bg-foreground/[0.06] text-muted-foreground border border-border/50 opacity-0 group-hover:opacity-100 transition-opacity">
                    {item.shortcut}
                  </kbd>
                )}
              </span>
            </button>
          );
        })}

        <div className="my-4 mx-3 border-t border-border" />

        {secondaryItems.map((item) => {
          const isActive = currentView === item.view;
          return (
            <button
              key={item.view}
              onClick={() => handleNavigate(item.view)}
              className={`w-full flex items-center justify-center lg:justify-start lg:space-x-3 px-3 py-2.5 rounded-xl transition-all duration-200 group border cursor-pointer ${
                isActive
                  ? "bg-gradient-to-r from-accent/15 to-accent-light/10 border-accent/15 shadow-[0_0_15px_rgba(0,0,0,0.15)] shadow-accent/10 text-accent font-bold"
                  : "text-gray-500 dark:text-gray-400 hover:text-foreground hover:bg-foreground/[0.04] border-transparent"
              }`}
            >
              <div className="relative shrink-0 flex items-center justify-center">
                <item.icon
                  size={20}
                  className={`transition-colors ${
                    isActive
                      ? "text-accent"
                      : "text-gray-500 dark:text-gray-400 group-hover:text-accent"
                  }`}
                />
              </div>
              <span className="hidden lg:flex items-center justify-between flex-1 text-[13px] font-semibold tracking-wide">
                <span>{item.label}</span>
                {item.shortcut && (
                  <kbd className="ml-auto text-[9px] font-mono font-bold px-1.5 py-0.5 rounded-md bg-foreground/[0.06] text-muted-foreground border border-border/50 opacity-0 group-hover:opacity-100 transition-opacity">
                    {item.shortcut}
                  </kbd>
                )}
              </span>
            </button>
          );
        })}
      </nav>
    </aside>
  );
}
