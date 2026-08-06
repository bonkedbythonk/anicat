export function ErrorBanner({ message, onDismiss }: { message: string; onDismiss?: () => void }) {
  if (!message) return null;
  return <div className="bg-danger/10 border border-danger/20 rounded-lg p-3 text-sm text-danger-light flex justify-between">{message}{onDismiss && <button onClick={onDismiss}>&times;</button>}</div>;
}
