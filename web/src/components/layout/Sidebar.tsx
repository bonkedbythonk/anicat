import { motion } from "framer-motion";
import { useAppStore } from "@/stores/app";
import {
  Home,
  Search,
  Download,
  Settings,
  Monitor,
  Bell,
  User,
  Calendar,
  BookOpen,
  PanelLeftClose,
  PanelLeft,
} from "lucide-react";

const navItems = [
  { icon: Home, label: "Home", view: "home" as const, shortcut: "H" },
  { icon: BookOpen, label: "Manga", view: "manga" as const, shortcut: "M" },
  { icon: Search, label: "Search", view: "search" as const, shortcut: "/" },
  { icon: Monitor, label: "My Lists", view: "lists" as const, shortcut: "L" },
  { icon: Download, label: "Downloads", view: "downloads" as const, shortcut: "D" },
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
  const compact = useAppStore((s) => s.sidebarCompact);
  const toggleSidebar = useAppStore((s) => s.toggleSidebar);

  const handleNavigate = (view: typeof currentView) => {
    if (selectedItem) closeDetail();
    setCurrentView(view);
  };

  return (
    <aside className="fixed left-0 top-0 bottom-0 z-50 flex flex-col py-6 transition-all duration-300 glass-fixed" style={{ width: compact ? 72 : 248 }}>
      <div
        data-tauri-drag-region
        className={`flex flex-col items-center justify-center mb-10 pt-14 cursor-default select-none w-full bg-black/[0.001] transition-all duration-300 ${
          compact ? "px-2" : "px-4 lg:px-6"
        }`}
      >
        <img
          src="/anicat_logo.png"
          alt="Anicat Logo"
          className={`opacity-95 hover:opacity-100 transition-all duration-300 object-contain pointer-events-none anicat-logo ${
            compact ? "w-8 h-8" : "w-24 lg:w-32"
          }`}
        />
        {import.meta.env.DEV && !compact && (
          <span className="mt-1.5 px-2 py-0.5 text-[9px] font-black uppercase tracking-widest bg-purple-500/10 text-purple-400 border border-purple-500/25 rounded-md select-none font-mono pointer-events-none animate-fade-in">
            Local Dev
          </span>
        )}
      </div>

      <nav className={`flex-1 space-y-1 pt-2 overflow-y-auto scrollbar-hide transition-all duration-300 ${
        compact ? "px-2" : "px-3 lg:px-6"
      }`}>
        {navItems.map((item) => {
          const isActive = currentView === item.view;
          return (
            <button
              key={item.view}
              onClick={() => handleNavigate(item.view)}
              className={`relative w-full flex items-center transition-colors duration-200 group border cursor-pointer border-transparent py-2.5 rounded-xl ${
                compact 
                  ? "justify-center px-0" 
                  : "justify-start pl-3 pr-6 space-x-3"
              }`}
            >
              {isActive && (
                <motion.div
                  layoutId={compact ? "nav-active-pill-compact" : "nav-active-pill-primary"}
                  className="absolute inset-0 rounded-xl bg-gradient-to-r from-accent/15 to-accent-light/10 border border-accent/15"
                  transition={{ type: "spring", stiffness: 380, damping: 35 }}
                />
              )}
              <item.icon
                size={20}
                className={`relative shrink-0 transition-colors ${
                  isActive
                    ? "text-accent"
                    : "text-gray-500 dark:text-gray-400 group-hover:text-accent"
                }`}
              />
              <span className={`relative items-center justify-between flex-1 text-[13px] font-semibold tracking-wide ${
                compact ? "hidden" : "flex"
              }`}>
                <span className={isActive ? "text-accent font-bold" : "text-gray-400"}>
                  {item.label}
                </span>
                {item.shortcut && (
                  <kbd
                    aria-hidden="true"
                    className="ml-auto text-[9px] font-mono font-bold px-1.5 py-0.5 rounded-md bg-foreground/[0.06] text-muted-foreground border border-border/50 hidden group-hover:inline-block"
                  >
                    {item.shortcut}
                  </kbd>
                )}
              </span>
            </button>
          );
        })}

        <div className={`my-4 border-t border-border transition-all duration-300 ${compact ? "mx-4" : "mx-3"}`} />

        {secondaryItems.map((item) => {
          const isActive = currentView === item.view;
          return (
            <button
              key={item.view}
              onClick={() => handleNavigate(item.view)}
              className={`relative w-full flex items-center transition-colors duration-200 group border cursor-pointer border-transparent py-2.5 rounded-xl ${
                compact 
                  ? "justify-center px-0" 
                  : "justify-start pl-3 pr-6 space-x-3"
              }`}
            >
              {isActive && (
                <motion.div
                  layoutId={compact ? "nav-active-pill-secondary-compact" : "nav-active-pill-secondary"}
                  className="absolute inset-0 rounded-xl bg-gradient-to-r from-accent/15 to-accent-light/10 border border-accent/15"
                  transition={{ type: "spring", stiffness: 380, damping: 35 }}
                />
              )}
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
              <span className={`relative items-center justify-between flex-1 text-[13px] font-semibold tracking-wide ${
                compact ? "hidden" : "flex"
              }`}>
                <span className={isActive ? "text-accent font-bold" : "text-gray-400"}>
                  {item.label}
                </span>
                {item.shortcut && (
                  <kbd
                    aria-hidden="true"
                    className="ml-auto text-[9px] font-mono font-bold px-1.5 py-0.5 rounded-md bg-foreground/[0.06] text-muted-foreground border border-border/50 hidden group-hover:inline-block"
                  >
                    {item.shortcut}
                  </kbd>
                )}
              </span>
            </button>
          );
        })}
      </nav>

      <div className={`mt-2 transition-all duration-300 ${compact ? "px-2" : "px-3 lg:px-6"}`}>
        <button
          onClick={toggleSidebar}
          className={`w-full flex items-center transition-colors duration-200 group border border-transparent hover:bg-white/[0.04] cursor-pointer text-gray-500 py-2.5 rounded-xl ${
            compact 
              ? "justify-center px-0" 
              : "justify-start pl-3 pr-6 space-x-3"
          }`}
          title={compact ? "Expand sidebar" : "Collapse sidebar"}
        >
          {compact ? (
            <PanelLeft size={20} className="shrink-0" />
          ) : (
            <PanelLeftClose size={20} className="shrink-0" />
          )}
          <span className={`relative items-center text-[13px] font-semibold tracking-wide text-gray-400 ${
            compact ? "hidden" : "flex"
          }`}>
            Collapse
          </span>
        </button>
      </div>
    </aside>
  );
}
