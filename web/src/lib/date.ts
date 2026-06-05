
export function formatTime(date: Date, format: '12h' | '24h' = '24h'): string {
  if (format === '24h') {
    return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
  }
  return date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: true });
}

export function formatRelativeTime(date: Date): string {
  const now = new Date();
  const diffInMs = date.getTime() - now.getTime();
  const diffInSeconds = Math.round(diffInMs / 1000);
  const diffInMinutes = Math.round(diffInSeconds / 60);
  const diffInHours = Math.round(diffInMinutes / 60);
  const diffInDays = Math.round(diffInHours / 24);

  if (diffInSeconds < 0) {
    return "Airing now or already aired";
  }

  if (diffInSeconds < 60) {
    return `in ${diffInSeconds}s`;
  }

  if (diffInMinutes < 60) {
    return `in ${diffInMinutes}m`;
  }

  if (diffInHours < 24) {
    return `in ${diffInHours}h`;
  }

  if (diffInDays < 7) {
    return `in ${diffInDays} day${diffInDays > 1 ? 's' : ''}`;
  }

  return date.toLocaleDateString();
}
