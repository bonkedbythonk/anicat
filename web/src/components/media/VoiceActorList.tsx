import { useMemo, useState } from "react";
import { proxyImage } from "@/lib/proxy";
import type { Character } from "@/lib/api";

type VoiceActor = NonNullable<Character["voiceActors"]>[number];

interface VoiceActorListProps {
  voiceActors: VoiceActor[];
  /** "JAPANESE" or "ENGLISH", from the viewer's sub/dub preference */
  preferredLanguage: string;
  /** Opens the actor's profile and filmography */
  onSelect?: (staffId: number) => void;
  compact?: boolean;
}

/**
 * A popular character can carry a dozen voice actors across eight dub
 * languages. Only the languages the viewer plausibly watches in are shown up
 * front; the rest sit behind a count.
 */
export function VoiceActorList({ voiceActors, preferredLanguage, onSelect, compact = false }: VoiceActorListProps) {
  const [showAll, setShowAll] = useState(false);

  const { visible, hiddenCount } = useMemo(() => {
    const rank = (va: VoiceActor) =>
      va.language === preferredLanguage ? 0 : va.language === "JAPANESE" || va.language === "ENGLISH" ? 1 : 2;
    const sorted = [...voiceActors].sort((a, b) => rank(a) - rank(b));
    if (showAll) return { visible: sorted, hiddenCount: 0 };
    const primary = sorted.filter((va) => rank(va) < 2);
    // Every credit is an obscure dub: show them rather than an empty list.
    const kept = primary.length > 0 ? primary : sorted;
    return { visible: kept, hiddenCount: sorted.length - kept.length };
  }, [voiceActors, preferredLanguage, showAll]);

  if (voiceActors.length === 0) return null;

  return (
    <div className="space-y-2">
      <div className={compact ? "space-y-2" : "grid grid-cols-1 sm:grid-cols-2 gap-2"}>
        {visible.map((va) => {
          const Row = onSelect ? "button" : "div";
          return (
            <Row
              key={`${va.id}-${va.language}`}
              {...(onSelect
                ? {
                    onClick: () => onSelect(va.id),
                    "aria-label": `See what ${va.name?.full} has voiced`,
                    className:
                      "flex items-center space-x-2 min-w-0 text-left rounded-md p-1 -m-1 hover:bg-foreground/[0.05] transition-colors group",
                  }
                : { className: "flex items-center space-x-2 min-w-0" })}
            >
              {va.image?.large && (
                <img
                  src={proxyImage(va.image.large)}
                  alt={va.name?.full}
                  loading="lazy"
                  className={`${compact ? "h-7 w-7" : "w-8 h-8"} rounded-full object-cover shrink-0`}
                />
              )}
              <div className="min-w-0">
                <div className={`text-xs text-foreground truncate ${onSelect ? "group-hover:text-accent transition-colors" : ""}`}>
                  {va.name?.full}
                </div>
                <div className="text-[10px] text-muted-foreground capitalize">{va.language?.toLowerCase()}</div>
              </div>
            </Row>
          );
        })}
      </div>
      {hiddenCount > 0 && (
        <button
          onClick={() => setShowAll(true)}
          className="text-[11px] font-bold text-foreground/50 hover:text-foreground transition-colors"
        >
          Show {hiddenCount} more {hiddenCount === 1 ? "language" : "languages"}
        </button>
      )}
    </div>
  );
}
