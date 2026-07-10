import { useState } from "react";
import { setMobileToken } from "@/lib/transport";

interface PinGateProps {
  onSuccess: () => void;
}

/** Shown before anything else on the mobile PWA — the anti-accidental-entry
 * gate. Calls /mobile-api/auth directly (not through the transport shim,
 * since there's no token yet); on success the returned token unlocks
 * everything else. */
export function PinGate({ onSuccess }: PinGateProps) {
  const [pin, setPin] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const submit = async () => {
    if (!pin) return;
    setSubmitting(true);
    setError(null);
    try {
      const res = await fetch("/mobile-api/auth", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ pin }),
      });
      if (!res.ok) {
        setError(res.status === 403 ? "Phone access is disabled on the desktop app." : "Wrong PIN.");
        setPin("");
        return;
      }
      const data = (await res.json()) as { token: string };
      setMobileToken(data.token);
      onSuccess();
    } catch {
      setError("Couldn't reach anicat. Is the desktop app running on this Wi-Fi?");
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="flex h-screen w-screen flex-col items-center justify-center bg-background text-foreground px-8 gap-6">
      <img src="/paw_icon.png" alt="Anicat" className="w-16 h-16" />
      <div className="text-center">
        <h1 className="text-xl font-bold">Enter PIN</h1>
        <p className="text-sm text-muted-foreground mt-1">Set on the desktop app's Settings &gt; Phone Access.</p>
      </div>
      <input
        type="tel"
        inputMode="numeric"
        autoFocus
        value={pin}
        onChange={(e) => setPin(e.target.value.replace(/\D/g, ""))}
        onKeyDown={(e) => { if (e.key === "Enter") submit(); }}
        maxLength={8}
        className="w-40 text-center text-3xl tracking-[0.5em] bg-card border border-border rounded-xl py-3 px-4 focus:outline-none focus:ring-2 focus:ring-accent"
        placeholder="----"
      />
      {error && <p className="text-sm text-red-400 max-w-xs text-center">{error}</p>}
      <button
        onClick={submit}
        disabled={submitting || !pin}
        className="px-6 py-2.5 rounded-xl bg-accent text-white font-semibold disabled:opacity-50"
      >
        {submitting ? "Checking..." : "Unlock"}
      </button>
    </div>
  );
}
