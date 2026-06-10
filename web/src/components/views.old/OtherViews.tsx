export function ScheduleView() {
  return (
    <div className="flex-1 overflow-y-auto p-6">
      <h1 className="text-2xl font-bold text-[var(--text-primary)]">Schedule</h1>
      <p className="text-[var(--text-secondary)] mt-2">Weekly anime airing schedule.</p>
    </div>
  );
}

export function NotificationsView() {
  return (
    <div className="flex-1 overflow-y-auto p-6">
      <h1 className="text-2xl font-bold text-[var(--text-primary)]">Notifications</h1>
      <p className="text-[var(--text-secondary)] mt-2">AniList activity notifications.</p>
    </div>
  );
}

export function ProfileView() {
  return (
    <div className="flex-1 overflow-y-auto p-6">
      <h1 className="text-2xl font-bold text-[var(--text-primary)]">Profile</h1>
      <p className="text-[var(--text-secondary)] mt-2">Your AniList profile and statistics.</p>
    </div>
  );
}

export function SettingsView() {
  return (
    <div className="flex-1 overflow-y-auto p-6">
      <h1 className="text-2xl font-bold text-[var(--text-primary)]">Settings</h1>
      <p className="text-[var(--text-secondary)] mt-2">Application configuration.</p>
    </div>
  );
}

export function DownloadsView() {
  return (
    <div className="flex-1 overflow-y-auto p-6">
      <h1 className="text-2xl font-bold text-[var(--text-primary)]">Downloads</h1>
      <p className="text-[var(--text-secondary)] mt-2">Downloaded episodes for offline viewing.</p>
    </div>
  );
}
