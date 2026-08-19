import { useMemo } from "react";
import { useInfiniteQuery } from "@tanstack/react-query";
import { ArrowLeft, Loader2 } from "lucide-react";
import { mediaApi, type MediaItem } from "@/lib/api";
import { proxyImage } from "@/lib/proxy";
import { sanitizeHtml, stripSpoilers } from "@/lib/sanitize";
import { formatFuzzyDate } from "@/lib/date";

interface StaffProfileProps {
  staffId: number;
  /** Opening a role's show replaces the whole detail page, so the host closes itself */
  onSelectMedia: (media: MediaItem) => void;
  onBack?: () => void;
  compact?: boolean;
}

/**
 * A voice actor's profile and filmography, sorted most-popular-first so the
 * roles they are known for lead. Rendered inside the desktop character modal
 * and the mobile character sheet alike.
 */
export function StaffProfile({ staffId, onSelectMedia, onBack, compact = false }: StaffProfileProps) {
  const { data, isLoading, isFetchingNextPage, hasNextPage, fetchNextPage, isError } = useInfiniteQuery({
    queryKey: ["staff", staffId],
    queryFn: ({ pageParam }) => mediaApi.getStaff(staffId, pageParam),
    getNextPageParam: (lastPage, allPages) => (lastPage?.hasNextPage ? allPages.length + 1 : undefined),
    initialPageParam: 1,
    staleTime: 6 * 60 * 60 * 1000,
  });

  const staff = data?.pages?.[0] ?? null;
  const roles = useMemo(() => (data?.pages ?? []).flatMap((p) => p?.roles ?? []), [data]);

  if (isLoading) {
    return (
      <div className="py-16 flex justify-center">
        <Loader2 className="animate-spin text-accent" size={22} />
      </div>
    );
  }

  if (isError || !staff) {
    return (
      <div className="py-12 text-center space-y-3">
        <p className="text-xs font-bold text-muted-foreground">Couldn't load this person's roles.</p>
        {onBack && (
          <button onClick={onBack} className="text-[11px] font-bold text-accent hover:underline">Back</button>
        )}
      </div>
    );
  }

  const facts = [
    { label: "Language", value: staff.language },
    { label: "Age", value: staff.age ? String(staff.age) : undefined },
    { label: "Birthday", value: formatFuzzyDate(staff.dateOfBirth) },
    { label: "From", value: staff.homeTown },
    // yearsActive is [start] while still working, [start, end] once retired.
    {
      label: "Active",
      value: staff.yearsActive.length
        ? `${staff.yearsActive[0]}${staff.yearsActive[1] ? `-${staff.yearsActive[1]}` : "-present"}`
        : undefined,
    },
    { label: "Favourites", value: staff.favourites ? staff.favourites.toLocaleString() : undefined },
  ].filter((f) => f.value);

  return (
    <div className="space-y-4">
      {onBack && (
        <button
          onClick={onBack}
          className="flex items-center gap-1.5 text-[11px] font-bold text-muted-foreground hover:text-foreground transition-colors"
        >
          <ArrowLeft size={13} />
          <span>Back to character</span>
        </button>
      )}

      <div className="flex items-start gap-4">
        {staff.image?.large && (
          <img
            src={proxyImage(staff.image.large)}
            alt={staff.name.full}
            className={`${compact ? "w-24" : "w-28"} shrink-0 aspect-[2/3] rounded-md object-cover`}
          />
        )}
        <div className="min-w-0 space-y-1">
          <div className="text-base font-bold text-foreground">{staff.name.full}</div>
          {staff.name.native && <div className="text-xs text-muted-foreground">{staff.name.native}</div>}
          {staff.occupations.length > 0 && (
            <div className="text-[11px] text-muted-foreground capitalize">{staff.occupations.join(", ").toLowerCase()}</div>
          )}
          <dl className="pt-1 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[11px]">
            {facts.map((f) => (
              <div key={f.label} className="contents">
                <dt className="text-muted-foreground">{f.label}</dt>
                <dd className="text-foreground font-medium">{f.value}</dd>
              </div>
            ))}
          </dl>
        </div>
      </div>

      {staff.description && (
        <div className="border-t border-border pt-3 space-y-1.5">
          <div className="meta-mono text-muted-foreground">About</div>
          {/* Spoilers cut before sanitizing — see MediaDetail. */}
          <div
            className="text-[12px] text-foreground/80 leading-relaxed whitespace-pre-line line-clamp-6"
            dangerouslySetInnerHTML={{ __html: sanitizeHtml(stripSpoilers(staff.description)) }}
          />
        </div>
      )}

      <div className="border-t border-border pt-3 space-y-2">
        <div className="flex items-baseline justify-between">
          <div className="meta-mono text-muted-foreground">Roles</div>
          {staff.totalRoles > 0 && (
            <div className="text-[10px] text-muted-foreground">
              {roles.length} of {staff.totalRoles}
            </div>
          )}
        </div>

        {roles.length === 0 ? (
          <p className="py-6 text-center text-xs font-bold text-muted-foreground">No roles listed.</p>
        ) : (
          <div className={`grid gap-2.5 ${compact ? "grid-cols-3" : "grid-cols-4"}`}>
            {roles.map((role, idx) => {
              const media = role.media;
              const character = role.characters[0];
              return (
                <button
                  key={`${media.id}-${character?.id ?? idx}`}
                  onClick={() => onSelectMedia(media)}
                  className="group text-left space-y-1"
                >
                  <div className="relative w-full aspect-[2/3] overflow-hidden rounded-md bg-foreground/5 border border-border group-hover:border-accent/40 transition-colors">
                    {media.cover_image?.large && (
                      <img
                        src={proxyImage(media.cover_image.large)}
                        alt={media.title?.english || media.title?.romaji || ""}
                        loading="lazy"
                        className="w-full h-full object-cover"
                      />
                    )}
                    {role.characterRole === "MAIN" && (
                      <span className="absolute top-1 left-1 px-1.5 py-0.5 rounded bg-accent text-[8px] font-black uppercase tracking-wider text-white">
                        Main
                      </span>
                    )}
                  </div>
                  <div className="text-[11px] font-bold text-foreground truncate group-hover:text-accent transition-colors">
                    {media.title?.english || media.title?.romaji}
                  </div>
                  {character && (
                    <div className="text-[10px] text-muted-foreground truncate">as {character.name.full}</div>
                  )}
                </button>
              );
            })}
          </div>
        )}

        {hasNextPage && (
          <button
            onClick={() => fetchNextPage()}
            disabled={isFetchingNextPage}
            className="w-full py-2 rounded-md border border-border text-[11px] font-bold text-muted-foreground hover:text-foreground hover:border-foreground/20 transition-colors disabled:opacity-50"
          >
            {isFetchingNextPage ? "Loading..." : "Load more roles"}
          </button>
        )}
      </div>
    </div>
  );
}
