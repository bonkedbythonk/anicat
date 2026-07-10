import { useQuery } from "@tanstack/react-query";
import { Calendar, BookOpen, Bell, User, ChevronRight } from "lucide-react";
import { getNotifications } from "@/lib/api";
import type { ViewType } from "@/lib/types";

interface MoreViewProps {
  onNavigate: (view: Extract<ViewType, "schedule" | "manga" | "notifications" | "profile">) => void;
}

/** A native "More" tab hub — the standard iOS pattern (Instagram, Uber,
 * countless others) for folding secondary sections behind one tab instead of
 * cramming every desktop nav item into the bottom bar. Grouped list rows,
 * not desktop's card grid — this screen has no desktop equivalent, it only
 * exists to keep the tab bar at 4 items. */
export function MoreView({ onNavigate }: MoreViewProps) {
  const { data: unreadCount } = useQuery({
    queryKey: ["more-unread-notifications"],
    queryFn: async () => {
      const lastCleared = Number(localStorage.getItem("anicat_last_notifications_cleared") || 0);
      const res = await getNotifications();
      const notifications = res?.Page?.notifications ?? [];
      return notifications.filter((n) => (n.createdAt || 0) > lastCleared).length;
    },
    staleTime: 60_000,
  });

  const rows: {
    icon: typeof Calendar;
    label: string;
    view: "schedule" | "manga" | "notifications" | "profile";
    badge?: number;
  }[] = [
    { icon: User, label: "Profile", view: "profile" },
    { icon: Calendar, label: "Schedule", view: "schedule" },
    { icon: BookOpen, label: "Manga", view: "manga" },
    { icon: Bell, label: "Notifications", view: "notifications", badge: unreadCount },
  ];

  return (
    <div className="animate-fade-in">
      <div className="rounded-2xl bg-white/[0.03] border border-white/[0.06] overflow-hidden">
        {rows.map((row, i) => {
          const Icon = row.icon;
          return (
            <button
              key={row.view}
              onClick={() => onNavigate(row.view)}
              className={`w-full flex items-center gap-3 px-4 py-3.5 active:bg-white/[0.06] transition-colors ${
                i > 0 ? "border-t border-white/[0.05]" : ""
              }`}
            >
              <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-accent/15 text-accent">
                <Icon size={17} />
              </div>
              <span className="flex-1 text-left text-[15px] font-semibold text-foreground">{row.label}</span>
              {!!row.badge && (
                <span className="min-w-[20px] h-5 px-1.5 rounded-full bg-accent text-white text-[11px] font-bold flex items-center justify-center">
                  {row.badge > 99 ? "99+" : row.badge}
                </span>
              )}
              <ChevronRight size={18} className="text-muted-foreground shrink-0" />
            </button>
          );
        })}
      </div>
    </div>
  );
}
