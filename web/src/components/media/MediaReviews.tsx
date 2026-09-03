import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { ThumbsUp, Star, MessageSquare, ChevronDown, ChevronUp, User } from "lucide-react";
import { mediaApi, type MediaReview } from "@/lib/api";
import { proxyImage } from "@/lib/proxy";
import { formatRelativeTimeFromUnix } from "@/lib/date";

interface MediaReviewsProps {
  mediaId: number;
}

export function MediaReviews({ mediaId }: MediaReviewsProps) {
  const [expandedIds, setExpandedIds] = useState<Set<number>>(new Set());

  const { data, isLoading, error } = useQuery({
    queryKey: ["media-reviews", mediaId],
    queryFn: () => mediaApi.getReviews(mediaId),
    staleTime: 1000 * 60 * 30, // 30 mins
  });

  const reviews: MediaReview[] = data?.Media?.reviews?.nodes || [];

  const toggleExpand = (id: number) => {
    setExpandedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  if (isLoading) {
    return (
      <div className="space-y-4 pt-2">
        {[1, 2].map((i) => (
          <div
            key={i}
            className="p-5 rounded-xl border border-border bg-foreground/[0.02] animate-pulse space-y-3"
          >
            <div className="flex items-center gap-3">
              <div className="w-9 h-9 rounded-full bg-foreground/10" />
              <div className="space-y-1.5 flex-1">
                <div className="h-4 w-32 bg-foreground/10 rounded" />
                <div className="h-3 w-20 bg-foreground/10 rounded" />
              </div>
              <div className="h-6 w-14 bg-foreground/10 rounded-full" />
            </div>
            <div className="h-4 w-3/4 bg-foreground/10 rounded" />
            <div className="h-12 w-full bg-foreground/10 rounded" />
          </div>
        ))}
      </div>
    );
  }

  if (error || reviews.length === 0) {
    return (
      <div className="py-16 text-center text-muted-foreground space-y-2">
        <MessageSquare size={32} className="mx-auto opacity-30" />
        <p className="text-sm font-medium">No community reviews yet for this title.</p>
        <p className="text-xs text-muted-foreground/60">
          Reviews from AniList users will appear here once published.
        </p>
      </div>
    );
  }

  return (
    <div className="space-y-4 pt-2">
      {reviews.map((rev) => {
        const isExpanded = expandedIds.has(rev.id);
        const isLong = rev.body.length > 320;
        const displayBody = isExpanded || !isLong ? rev.body : `${rev.body.slice(0, 320)}...`;

        const scoreColor =
          rev.score >= 75
            ? "bg-emerald-500/15 text-emerald-400 border-emerald-500/30"
            : rev.score >= 50
              ? "bg-amber-500/15 text-amber-400 border-amber-500/30"
              : "bg-rose-500/15 text-rose-400 border-rose-500/30";

        return (
          <article
            key={rev.id}
            className="p-5 rounded-xl border border-border bg-foreground/[0.02] hover:bg-foreground/[0.035] transition-colors space-y-3"
          >
            {/* Header: User, Score, Date */}
            <div className="flex items-center justify-between gap-3">
              <div className="flex items-center gap-3 min-w-0">
                {rev.user.avatar?.medium ? (
                  <img
                    src={proxyImage(rev.user.avatar.medium)}
                    alt={rev.user.name}
                    className="w-9 h-9 rounded-full object-cover border border-border flex-shrink-0"
                  />
                ) : (
                  <div className="w-9 h-9 rounded-full bg-surface flex items-center justify-center border border-border flex-shrink-0 text-muted-foreground">
                    <User size={16} />
                  </div>
                )}
                <div className="min-w-0">
                  <div className="text-[13px] font-semibold text-foreground truncate">
                    {rev.user.name}
                  </div>
                  <div className="text-[11px] text-muted-foreground meta-mono">
                    {formatRelativeTimeFromUnix(rev.createdAt)}
                  </div>
                </div>
              </div>

              <div className="flex items-center gap-2 flex-shrink-0">
                {rev.ratingAmount > 0 && (
                  <div className="hidden sm:flex items-center gap-1 text-[11px] text-muted-foreground mr-1">
                    <ThumbsUp size={12} className="opacity-70" />
                    <span>
                      {rev.rating}/{rev.ratingAmount}
                    </span>
                  </div>
                )}
                <div
                  className={`flex items-center gap-1 px-2.5 py-1 rounded-full text-xs font-bold border ${scoreColor}`}
                >
                  <Star size={11} className="fill-current" />
                  <span>{rev.score}%</span>
                </div>
              </div>
            </div>

            {/* Review Summary */}
            {rev.summary && (
              <p className="text-sm font-semibold text-foreground/95 italic border-l-2 border-accent/60 pl-3 py-0.5">
                "{rev.summary}"
              </p>
            )}

            {/* Review Body */}
            <div className="text-[13px] text-foreground/80 leading-relaxed whitespace-pre-line font-normal">
              {displayBody}
            </div>

            {/* Expand / Collapse toggle */}
            {isLong && (
              <button
                onClick={() => toggleExpand(rev.id)}
                className="flex items-center gap-1 text-xs font-medium text-accent hover:underline pt-1 cursor-pointer"
              >
                {isExpanded ? (
                  <>
                    <span>Show less</span>
                    <ChevronUp size={14} />
                  </>
                ) : (
                  <>
                    <span>Read full review</span>
                    <ChevronDown size={14} />
                  </>
                )}
              </button>
            )}
          </article>
        );
      })}
    </div>
  );
}
