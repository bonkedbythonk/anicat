import { useEffect, useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { List, Loader2, Play, X } from "lucide-react";
import { mediaApi, type StreamServer } from "@/lib/api";
import { useModalDismiss } from "@/hooks/useModalDismiss";

interface CinemaReleasePickerProps {
  mediaId: number;
  /** Absolute episode number for a series, or 1 for a film — whatever
   *  `mediaApi.play`'s second argument already is at the call site. */
  episodeNumber: number;
  label: string;
  onClose: () => void;
  onPick: (releaseName: string) => void;
}

/** Lets the auto-pick be overridden when it is wrong: a dead swarm, a bad
 *  rip, a release the codec filter should have caught but did not. The anime
 *  side has had this since the release picker existed; cinema mode played
 *  through the auto-pick alone with no way back if it failed.
 *
 *  A modal rather than an inline list, unlike the anime episode picker: this
 *  is reached from one Play button, not from a per-episode row in a list, so
 *  there is nothing to keep it anchored to. */
export function CinemaReleasePicker({
  mediaId,
  episodeNumber,
  label,
  onClose,
  onPick,
}: CinemaReleasePickerProps) {
  const modalRef = useModalDismiss<HTMLDivElement>(true, onClose);

  const releases = useQuery({
    queryKey: ["cinema-releases", mediaId, episodeNumber],
    queryFn: () => mediaApi.getStreams(mediaId, episodeNumber) as Promise<{ streams?: StreamServer[] }>,
  });

  // The search behind this can legitimately take up to ~20s -- a torrent
  // indexer timeout, not a bug -- and a bare spinner with no change for that
  // long reads as frozen. Say so once it's been a while, rather than staying
  // silent right up until either an answer or "no releases" appears.
  const [slow, setSlow] = useState(false);
  useEffect(() => {
    setSlow(false);
    const t = setTimeout(() => setSlow(true), 6000);
    return () => clearTimeout(t);
  }, [mediaId, episodeNumber]);

  const sorted = [...(releases.data?.streams ?? [])].sort(
    (a, b) => (b.seeders ?? 0) - (a.seeders ?? 0),
  );

  return (
    <div
      ref={modalRef}
      className="fixed inset-0 z-[300] flex items-center justify-center bg-black/50 p-6"
      role="dialog"
      aria-modal="true"
      aria-label={`Choose a release for ${label}`}
    >
      <div className="flex max-h-[70vh] w-[min(560px,100%)] flex-col overflow-hidden rounded-lg border border-border bg-surface shadow-2xl">
        <div className="flex items-center justify-between border-b border-border px-5 py-4">
          <div className="flex items-center gap-2">
            <List size={15} className="text-muted-foreground" aria-hidden="true" />
            <h2 className="text-[13px] font-semibold text-foreground">Choose a release</h2>
          </div>
          <button
            onClick={onClose}
            aria-label="Close"
            className="cursor-pointer rounded-md p-1 text-muted-foreground hover:text-foreground"
          >
            <X size={16} />
          </button>
        </div>

        <div className="overflow-y-auto p-2">
          {(releases.isLoading || releases.isFetching) && sorted.length === 0 ? (
            <div className="flex flex-col items-center gap-3 py-10">
              <Loader2 className="animate-spin text-accent" size={22} />
              {slow && (
                <p className="px-3 text-center text-[12px] text-muted-foreground">
                  Still searching — torrent indexers can take a while to answer.
                </p>
              )}
            </div>
          ) : sorted.length === 0 ? (
            <p className="px-3 py-8 text-center text-[13px] text-muted-foreground">
              No releases found for {label}.
            </p>
          ) : (
            sorted.map((s) => <ReleaseRow key={s.name} server={s} onPick={() => onPick(s.name)} />)
          )}
        </div>
      </div>
    </div>
  );
}

function ReleaseRow({ server, onPick }: { server: StreamServer; onPick: () => void }) {
  return (
    <button
      onClick={onPick}
      className="group flex w-full cursor-pointer items-center justify-between gap-3 rounded-md px-3 py-2.5 text-left hover:bg-foreground/[0.05]"
    >
      <span className="min-w-0 flex-1 truncate text-[12.5px] text-foreground/85">{server.name}</span>
      <span className="flex shrink-0 items-center gap-3">
        {typeof server.seeders === "number" && (
          <span className="meta-mono text-muted-foreground">{server.seeders} seeders</span>
        )}
        <Play
          size={13}
          className="text-muted-foreground opacity-0 group-hover:opacity-100 group-hover:text-accent"
          aria-hidden="true"
        />
      </span>
    </button>
  );
}

/** Small trigger button, shared by the film and episode rows so the picker
 *  looks and behaves the same in both. */
export function ChooseReleaseButton({ onClick }: { onClick: (e: React.MouseEvent) => void }) {
  return (
    <button
      onClick={onClick}
      title="Choose a different release"
      aria-label="Choose a different release"
      className="flex cursor-pointer items-center justify-center rounded-md border border-border p-2 text-muted-foreground hover:border-foreground/25 hover:text-foreground"
    >
      <List size={14} aria-hidden="true" />
    </button>
  );
}
