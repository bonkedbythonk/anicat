import { useEffect, useState } from "react";
import { setMobileToken, setMobileUser } from "@/lib/transport";

interface PinGateProps {
  onSuccess: () => void;
}

/** Shown before anything else on the mobile PWA — the anti-accidental-entry
 * gate (single-PIN mode) or the per-user login screen (multi-user mode,
 * Stage 2). Calls /mobile-api/auth or /mobile-api/session/login directly
 * (not through the transport shim, since there's no token yet); on success
 * the returned token unlocks everything else.
 *
 * Which mode to show comes from /mobile-api/lan-info's `multi_user` flag —
 * fetched once on mount, before rendering either form, so a phone never
 * flashes the wrong one. */
export function PinGate({ onSuccess }: PinGateProps) {
  const [multiUser, setMultiUser] = useState<boolean | null>(null);
  const [displayName, setDisplayName] = useState("");
  const [pin, setPin] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    fetch("/mobile-api/lan-info")
      .then((res) => res.json())
      .then((data: { multi_user: boolean }) => setMultiUser(data.multi_user))
      .catch(() => setMultiUser(false)); // can't reach the server at all — fall back to the simpler form, submit will report the real error
  }, []);

  const submit = async () => {
    if (!pin || (multiUser && !displayName)) return;
    setSubmitting(true);
    setError(null);
    try {
      const res = await fetch(multiUser ? "/mobile-api/session/login" : "/mobile-api/auth", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(multiUser ? { display_name: displayName, pin } : { pin }),
      });
      if (!res.ok) {
        setError(
          multiUser
            ? "Wrong name or PIN."
            : res.status === 403
              ? "Phone access is disabled on the desktop app."
              : "Wrong PIN.",
        );
        setPin("");
        return;
      }
      if (multiUser) {
        const data = (await res.json()) as { token: string; user_id: number; display_name: string };
        setMobileToken(data.token);
        setMobileUser({ userId: data.user_id, displayName: data.display_name });
      } else {
        const data = (await res.json()) as { token: string };
        setMobileToken(data.token);
      }
      onSuccess();
    } catch {
      setError("Couldn't reach anicat. Check your connection.");
    } finally {
      setSubmitting(false);
    }
  };

  if (multiUser === null) {
    // Briefly blank while lan-info resolves — faster than a spinner would
    // read for what's normally a same-network, sub-100ms round trip.
    return <div className="h-screen w-screen bg-background" />;
  }

  return (
    <div className="flex h-screen w-screen flex-col items-center justify-center bg-background text-foreground px-8 gap-6">
      <img src="/paw_icon.png" alt="Anicat" className="w-16 h-16" />
      <div className="text-center">
        <h1 className="text-xl font-bold">{multiUser ? "Who's watching?" : "Enter PIN"}</h1>
        <p className="text-sm text-muted-foreground mt-1">
          {multiUser ? "Enter your name and PIN." : "Set on the desktop app's Settings > Phone Access."}
        </p>
      </div>
      {multiUser && (
        <input
          type="text"
          autoFocus
          autoComplete="off"
          autoCorrect="off"
          autoCapitalize="words"
          spellCheck={false}
          value={displayName}
          onChange={(e) => setDisplayName(e.target.value)}
          placeholder="Your name"
          className="w-56 text-center text-lg bg-card border border-border rounded-md py-3 px-4 focus:outline-none focus:ring-2 focus:ring-accent"
        />
      )}
      <input
        type="tel"
        inputMode="numeric"
        autoFocus={!multiUser}
        value={pin}
        onChange={(e) => setPin(e.target.value.replace(/\D/g, ""))}
        onKeyDown={(e) => { if (e.key === "Enter") submit(); }}
        maxLength={8}
        className="w-40 text-center text-3xl tracking-[0.5em] bg-card border border-border rounded-md py-3 px-4 focus:outline-none focus:ring-2 focus:ring-accent"
        placeholder="----"
      />
      {error && <p className="text-sm text-danger-light max-w-xs text-center">{error}</p>}
      <button
        onClick={submit}
        disabled={submitting || !pin || (!!multiUser && !displayName)}
        className="px-6 py-2.5 rounded-md bg-accent text-background font-semibold disabled:opacity-50"
      >
        {submitting ? "Checking..." : "Unlock"}
      </button>
    </div>
  );
}
