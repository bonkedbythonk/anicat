

// SQLite datetime('now') strings are UTC without a zone suffix; without this,
// `new Date(s)` parses them as local time and every "watched Xh ago" display
// silently drifts by the viewer's UTC offset.
export function parseWatchedAt(s: string): Date {
  return new Date(s.includes("T") ? s : `${s.replace(" ", "T")}Z`);
}

/**
 * AniList fuzzy dates carry whatever parts are known — a character birthday
 * is usually month + day with no year. Renders only the known parts, and
 * returns undefined when nothing is known so callers can drop the row.
 */
export function formatFuzzyDate(
  date?: { year?: number | null; month?: number | null; day?: number | null } | null,
): string | undefined {
  if (!date?.month && !date?.day && !date?.year) return undefined;
  const MONTHS = ["January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"];
  const month = date.month ? MONTHS[date.month - 1] : undefined;
  const parts = [month && date.day ? `${month} ${date.day}` : month ?? (date.day ? `Day ${date.day}` : undefined)];
  if (date.year) parts.push(String(date.year));
  return parts.filter(Boolean).join(", ") || undefined;
}

export function parseAiringTime(airingAt?: string | number | null): number {
  if (!airingAt) return 0;
  if (typeof airingAt === "number") {
    return airingAt > 10000000000 ? airingAt : airingAt * 1000;
  }
  return new Date(airingAt.endsWith("Z") ? airingAt : `${airingAt}Z`).getTime();
}

export function formatTime(seconds: number): string {
  if (!seconds || seconds < 0) return "0:00";
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  if (h > 0) return `${h}:${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")}`;
  return `${m}:${s.toString().padStart(2, "0")}`;
}

export function formatRelativeTime(dateStr: string): string {
  const date = new Date(dateStr);
  const now = new Date();
  const diff = now.getTime() - date.getTime();
  if (diff < 0) return date.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
  const minutes = Math.floor(diff / 60000);
  const hours = Math.floor(diff / 3600000);
  const days = Math.floor(diff / 86400000);

  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes}m ago`;
  if (hours < 24) return `${hours}h ago`;
  if (days < 7) return `${days}d ago`;

  return date.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    ...(date.getFullYear() !== now.getFullYear() && { year: "numeric" }),
  });
}

// Compound-precision countdown ("in 2d 4h", "in 3h 12m", "in 5m") for contexts
// that want more granularity than formatRelativeTimeFromUnix's single-unit
// output — e.g. a hero countdown chip where "in 1d" vs "in 1d 23h" matters.
export function formatAiringCountdown(airingAt?: string | number | null): string | null {
  if (!airingAt) return null;
  const t = parseAiringTime(airingAt);
  if (!t) return null;
  const diff = t - Date.now();
  if (diff <= 0) return "aired";
  const days = Math.floor(diff / 86_400_000);
  const hours = Math.floor((diff % 86_400_000) / 3_600_000);
  if (days > 0) return `in ${days}d ${hours}h`;
  const mins = Math.floor((diff % 3_600_000) / 60_000);
  return hours > 0 ? `in ${hours}h ${mins}m` : `in ${mins}m`;
}

export function formatRelativeTimeFromUnix(unixSeconds: number | string): string {
  if (!unixSeconds) return "Unknown";
  let date: Date;
  if (typeof unixSeconds === "string") {
    date = new Date(unixSeconds);
  } else {
    const val = Number(unixSeconds);
    if (val > 10000000000) {
      date = new Date(val);
    } else {
      date = new Date(val * 1000);
    }
  }

  if (isNaN(date.getTime())) return "Unknown";
  const now = new Date();
  const diff = date.getTime() - now.getTime();
  const minutes = Math.floor(diff / 60000);
  const hours = Math.floor(diff / 3600000);
  const days = Math.floor(diff / 86400000);

  if (diff < 0) return "aired";
  if (minutes < 60) return `in ${minutes}m`;
  if (hours < 24) return `in ${hours}h`;
  if (days < 7) return `in ${days}d`;
  return date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}
