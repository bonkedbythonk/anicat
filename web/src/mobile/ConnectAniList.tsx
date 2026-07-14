import { useState } from "react";
import { mobileFetch } from "@/lib/transport";

interface ConnectAniListProps {
  displayName: string;
  onConnected: () => void;
}

// AniList's own client id for anicat, same one desktop's commands::auth uses.
const ANILIST_AUTHORIZE_URL = "https://anilist.co/api/v2/oauth/authorize?client_id=20148&response_type=token";

/** Shown after a successful login (single-PIN or per-user) when
 * /mobile-api/session/whoami reports no AniList account connected yet.
 * Desktop's OAuth flow shells out to a browser via `open::that()`, which
 * doesn't exist here — instead this opens AniList's authorize page in the
 * phone's own browser and asks the person to paste back the redirect URL
 * (or bare token), same UX desktop's Settings/Onboarding already use for
 * the same reason (no way to intercept the redirect server-side). */
export function ConnectAniList({ displayName, onConnected }: ConnectAniListProps) {
  const [pasted, setPasted] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const submit = async () => {
    const hashMatch = pasted.trim().match(/#.*access_token=([^&]+)/);
    const token = hashMatch ? decodeURIComponent(hashMatch[1]) : pasted.trim();
    if (token.length < 20) {
      setError("That doesn't look like a valid token or redirect URL.");
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      const res = await mobileFetch("/mobile-api/user/connect-anilist", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ token }),
      });
      if (!res.ok) {
        setError("Couldn't verify that token with AniList.");
        return;
      }
      onConnected();
    } catch {
      setError("Couldn't reach anicat.");
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="flex h-screen w-screen flex-col items-center justify-center bg-background text-foreground px-8 gap-5 text-center">
      <img src="/paw_icon.png" alt="Anicat" className="w-14 h-14" />
      <div>
        <h1 className="text-xl font-bold">Hi, {displayName}</h1>
        <p className="text-sm text-muted-foreground mt-1 max-w-xs">
          Connect your own AniList account to track your own watch progress and lists.
        </p>
      </div>
      <a
        href={ANILIST_AUTHORIZE_URL}
        target="_blank"
        rel="noreferrer"
        className="px-6 py-2.5 rounded-xl bg-accent text-white font-semibold"
      >
        Connect AniList
      </a>
      <p className="text-xs text-muted-foreground max-w-xs">
        After authorizing, paste the page's URL (or just the token) below.
      </p>
      <input
        type="text"
        value={pasted}
        onChange={(e) => setPasted(e.target.value)}
        placeholder="Paste redirect URL or token..."
        className="w-full max-w-xs bg-card border border-border rounded-xl py-3 px-4 text-sm focus:outline-none focus:ring-2 focus:ring-accent"
      />
      {error && <p className="text-sm text-red-400 max-w-xs">{error}</p>}
      <button
        onClick={submit}
        disabled={submitting || !pasted}
        className="px-6 py-2.5 rounded-xl bg-white/15 font-semibold disabled:opacity-50"
      >
        {submitting ? "Connecting..." : "Save"}
      </button>
    </div>
  );
}
