import { useQuery } from "@tanstack/react-query";
import { getUser } from "@/lib/api";

export function ProfileView() {
  const { data, isLoading } = useQuery({
    queryKey: ["profile"],
    queryFn: () => getUser(),
    staleTime: 120_000,
  });

  const viewer = data?.Viewer;

  if (isLoading) {
    return (
      <div className="flex-1 overflow-y-auto p-6 flex items-center justify-center">
        <div className="animate-spin h-6 w-6 border-2 border-[var(--accent)] border-t-transparent rounded-full" />
      </div>
    );
  }

  if (!viewer) {
    return (
      <div className="flex-1 overflow-y-auto p-6">
        <h1 className="text-2xl font-bold text-[var(--text-primary)] mb-4">Profile</h1>
        <p className="text-[var(--text-secondary)]">Log in to AniList to see your profile.</p>
      </div>
    );
  }

  const stats = viewer.statistics?.anime;

  return (
    <div className="flex-1 overflow-y-auto p-6">
      <div className="flex items-center gap-4 mb-6">
        {viewer.avatar?.large && (
          <img
            src={viewer.avatar.large}
            alt={viewer.name}
            className="w-16 h-16 rounded-full object-cover"
          />
        )}
        <div>
          <h1 className="text-2xl font-bold text-[var(--text-primary)]">{viewer.name}</h1>
          {viewer.about && (
            <p className="text-sm text-[var(--text-secondary)] mt-1">{viewer.about}</p>
          )}
        </div>
      </div>

      {stats && (
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-4 mb-6">
          <StatCard label="Anime Watched" value={stats.count} />
          <StatCard label="Episodes" value={stats.episodesWatched} />
          <StatCard label="Minutes" value={stats.minutesWatched} />
          <StatCard label="Mean Score" value={stats.meanScore?.toFixed(1)} />
        </div>
      )}
    </div>
  );
}

function StatCard({ label, value }: { label: string; value: number | string | undefined }) {
  return (
    <div className="bg-[var(--bg-tertiary)] rounded-xl p-4">
      <p className="text-xs text-[var(--text-muted)]">{label}</p>
      <p className="text-xl font-bold text-[var(--text-primary)] mt-1">
        {typeof value === "number" ? value.toLocaleString() : value || "-"}
      </p>
    </div>
  );
}
