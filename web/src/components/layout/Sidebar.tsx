import { useAppStore } from "@/stores/app";
import {
  Home,
  Search,
  Library,
  List,
  Calendar,
  Bell,
  User,
  Settings,
  Download,
} from "lucide-react";

const NAV_ITEMS = [
  { view: "home" as const, label: "Home", icon: Home, key: "1" },
  { view: "search" as const, label: "Search", icon: Search, key: "2" },
  { view: "library" as const, label: "Library", icon: Library, key: "3" },
  { view: "lists" as const, label: "Lists", icon: List, key: "4" },
  { view: "schedule" as const, label: "Schedule", icon: Calendar, key: "5" },
  { view: "notifications" as const, label: "Notifications", icon: Bell, key: "6" },
  { view: "profile" as const, label: "Profile", icon: User, key: "7" },
  { view: "settings" as const, label: "Settings", icon: Settings, key: "8" },
  { view: "downloads" as const, label: "Downloads", icon: Download, key: "9" },
];

export function Sidebar() {
  const { currentView, setCurrentView, selectedItem, closeDetail } = useAppStore();

  const handleClick = (view: typeof currentView) => {
    if (selectedItem) closeDetail();
    setCurrentView(view);
  };

  return (
    <aside className="w-[60px] flex flex-col items-center py-4 gap-1 border-r border-[var(--border)] shrink-0 relative z-10 bg-[var(--bg-glass)] backdrop-blur-xl">
      <div className="mb-4 flex items-center justify-center">
        <img
          src="/logo.png"
          alt="Anicat"
          className="w-8 h-8 rounded-lg"
          onError={(e) => {
            (e.target as HTMLImageElement).style.display = "none";
          }}
        />
      </div>
      {NAV_ITEMS.map((item) => {
        const isActive = currentView === item.view;
        return (
          <button
            key={item.view}
            onClick={() => handleClick(item.view)}
            className={`w-10 h-10 rounded-xl flex items-center justify-center transition-all ${
              isActive
                ? "bg-[var(--accent)] text-white shadow-[var(--accent-glow)]"
                : "text-[var(--text-muted)] hover:text-[var(--text-primary)] hover:bg-[var(--bg-tertiary)]"
            }`}
            title={`${item.label} (${item.key})`}
          >
            <item.icon size={18} />
          </button>
        );
      })}
    </aside>
  );
}
