import { useQuery } from "@tanstack/react-query";
import { getNotifications } from "@/lib/api";
import { useAppStore } from "@/stores/app";
import type { Notification } from "@/lib/types";

export function NotificationsView() {
  const openDetail = useAppStore((s) => s.openDetail);

  const { data, isLoading } = useQuery({
    queryKey: ["notifications"],
    queryFn: () => getNotifications(),
    staleTime: 60_000,
  });

  const notifications: Notification[] =
    (data?.data?.Page?.notifications as Notification[]) || [];

  return (
    <div className="flex-1 overflow-y-auto p-6">
      <h1 className="text-2xl font-bold text-[var(--text-primary)] mb-6">Notifications</h1>

      {isLoading ? (
        <div className="flex justify-center py-12">
          <div className="animate-spin h-6 w-6 border-2 border-[var(--accent)] border-t-transparent rounded-full" />
        </div>
      ) : notifications.length === 0 ? (
        <p className="text-[var(--text-secondary)]">No notifications yet.</p>
      ) : (
        <div className="space-y-3">
          {notifications.map((n) => (
            <div
              key={n.id}
              className="flex items-start gap-3 p-3 rounded-lg bg-[var(--bg-tertiary)]"
            >
              {n.media?.coverImage?.medium && (
                <img
                  src={n.media.coverImage.medium}
                  alt=""
                  className="w-10 h-10 rounded object-cover shrink-0"
                />
              )}
              <div className="flex-1 min-w-0">
                <p className="text-sm text-[var(--text-primary)]">{n.context || n.type}</p>
                {n.media && (
                  <button
                    onClick={() => openDetail(n.media!)}
                    className="text-xs text-[var(--accent)] hover:underline mt-0.5"
                  >
                    {n.media.title.romaji || n.media.title.english}
                  </button>
                )}
              </div>
              <span className="text-[10px] text-[var(--text-muted)] shrink-0">
                {new Date(n.createdAt * 1000).toLocaleDateString()}
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
