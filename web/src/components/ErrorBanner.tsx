export function ErrorBanner({ message, onDismiss }: { message: string; onDismiss?: () => void }) {
  if (!message) return null;
  return <div className="bg-red-500/10 border border-red-500/20 rounded-lg p-3 text-sm text-red-400 flex justify-between">{message}{onDismiss && <button onClick={onDismiss}>&times;</button>}</div>;
}
