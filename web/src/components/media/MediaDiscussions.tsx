import { useState, useMemo } from "react";
import { useQuery } from "@tanstack/react-query";
import {
  MessageSquare,
  Star,
  Loader2,
  ThumbsUp,
  Clock,
  User,
  X,
  ExternalLink,
  ChevronRight,
  Eye,
} from "lucide-react";
import {
  mediaApi,
} from "@/lib/api";
import { proxyImage } from "@/lib/proxy";
import { sanitizeHtml } from "@/lib/sanitize";

interface MediaDiscussionsProps {
  mediaId: number;
  mediaTitle?: string;
  isManga?: boolean;
}

function formatRelativeTime(timestampSec: number): string {
  if (!timestampSec) return "";
  const now = Date.now() / 1000;
  const diff = now - timestampSec;
  if (diff < 60) return "Just now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  if (diff < 2592000) return `${Math.floor(diff / 86400)}d ago`;
  if (diff < 31536000) return `${Math.floor(diff / 2592000)}mo ago`;
  return `${Math.floor(diff / 31536000)}y ago`;
}

function CommentBody({ content }: { content: string }) {
  // Convert ~!spoiler!~ markdown to styled spans
  const processed = useMemo(() => {
    if (!content) return "";
    const html = content
      .replace(/~!([\s\S]*?)!~/g, '<span class="spoiler-block cursor-pointer bg-foreground/20 hover:bg-foreground/30 px-1 py-0.5 rounded text-transparent hover:text-foreground transition-colors select-none" title="Click to reveal spoiler">$1</span>')
      .replace(/\n/g, "<br />");
    return sanitizeHtml(html);
  }, [content]);

  return (
    <div
      className="text-[13px] text-foreground/80 leading-relaxed break-words space-y-2 prose-invert"
      dangerouslySetInnerHTML={{ __html: processed }}
    />
  );
}

export function MediaDiscussions({ mediaId, isManga = false }: MediaDiscussionsProps) {
  const [subTab, setSubTab] = useState<"discussions" | "reviews">("discussions");
  const [threadFilter, setThreadFilter] = useState<"all" | "episodes" | "general">("all");
  const [selectedThreadId, setSelectedThreadId] = useState<number | null>(null);
  const [expandedReviewId, setExpandedReviewId] = useState<number | null>(null);

  const { data, isLoading, isError } = useQuery({
    queryKey: ["media-community", mediaId],
    queryFn: () => mediaApi.getMediaCommunity(mediaId),
    staleTime: 5 * 60 * 1000,
  });

  const { data: threadDetail, isLoading: loadingThread } = useQuery({
    queryKey: ["thread-detail", selectedThreadId],
    queryFn: () => (selectedThreadId ? mediaApi.getThreadDetails(selectedThreadId) : null),
    enabled: selectedThreadId !== null,
  });

  const threads = useMemo(() => data?.threads?.threads || [], [data]);
  const reviews = useMemo(() => data?.reviews?.reviews || [], [data]);

  const filteredThreads = useMemo(() => {
    if (threadFilter === "episodes") {
      return threads.filter((t) =>
        /episode|chapter|premiere|finale/i.test(t.title)
      );
    }
    if (threadFilter === "general") {
      return threads.filter(
        (t) => !/episode|chapter|premiere|finale/i.test(t.title)
      );
    }
    return threads;
  }, [threads, threadFilter]);

  if (isLoading) {
    return (
      <div className="py-20 flex flex-col items-center justify-center gap-3 text-muted-foreground">
        <Loader2 className="animate-spin text-accent" size={26} />
        <span className="text-xs font-medium font-mono">Loading community discussions & reviews...</span>
      </div>
    );
  }

  if (isError) {
    return (
      <div className="py-16 text-center text-xs text-muted-foreground">
        Could not load discussions for this title right now.
      </div>
    );
  }

  return (
    <div className="space-y-5">
      {/* Sub-tab Switcher: Discussions & Reviews */}
      <div className="flex items-center justify-between border-b border-border pb-3 flex-wrap gap-3">
        <div className="flex items-center gap-1.5 bg-surface p-1 rounded-lg border border-border">
          <button
            onClick={() => setSubTab("discussions")}
            className={`flex items-center gap-2 px-3 py-1.5 rounded-md text-xs font-semibold transition-all cursor-pointer ${
              subTab === "discussions"
                ? "bg-accent text-background shadow-xs"
                : "text-muted-foreground hover:text-foreground"
            }`}
          >
            <MessageSquare size={14} />
            <span>Discussions</span>
            {threads.length > 0 && (
              <span className="px-1.5 py-0.2 rounded-full bg-foreground/10 text-[10px] font-mono">
                {threads.length}
              </span>
            )}
          </button>

          <button
            onClick={() => setSubTab("reviews")}
            className={`flex items-center gap-2 px-3 py-1.5 rounded-md text-xs font-semibold transition-all cursor-pointer ${
              subTab === "reviews"
                ? "bg-accent text-background shadow-xs"
                : "text-muted-foreground hover:text-foreground"
            }`}
          >
            <Star size={14} />
            <span>Reviews</span>
            {reviews.length > 0 && (
              <span className="px-1.5 py-0.2 rounded-full bg-foreground/10 text-[10px] font-mono">
                {reviews.length}
              </span>
            )}
          </button>
        </div>

        {subTab === "discussions" && threads.length > 0 && (
          <div className="flex items-center gap-1 text-[11px] font-mono">
            <button
              onClick={() => setThreadFilter("all")}
              className={`px-2.5 py-1 rounded-md transition-all cursor-pointer ${
                threadFilter === "all"
                  ? "bg-foreground/10 text-foreground font-bold"
                  : "text-muted-foreground hover:text-foreground"
              }`}
            >
              All
            </button>
            <button
              onClick={() => setThreadFilter("episodes")}
              className={`px-2.5 py-1 rounded-md transition-all cursor-pointer ${
                threadFilter === "episodes"
                  ? "bg-foreground/10 text-foreground font-bold"
                  : "text-muted-foreground hover:text-foreground"
              }`}
            >
              {isManga ? "Chapters" : "Episodes"}
            </button>
            <button
              onClick={() => setThreadFilter("general")}
              className={`px-2.5 py-1 rounded-md transition-all cursor-pointer ${
                threadFilter === "general"
                  ? "bg-foreground/10 text-foreground font-bold"
                  : "text-muted-foreground hover:text-foreground"
              }`}
            >
              General
            </button>
          </div>
        )}
      </div>

      {/* Discussions Content */}
      {subTab === "discussions" && (
        <div className="space-y-3">
          {filteredThreads.length === 0 ? (
            <div className="py-16 text-center text-xs text-muted-foreground">
              No discussion threads found.
            </div>
          ) : (
            <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
              {filteredThreads.map((thread) => {
                const isEpDiscussion = /episode|chapter|premiere|finale/i.test(thread.title);
                return (
                  <button
                    key={thread.id}
                    onClick={() => setSelectedThreadId(thread.id)}
                    className="flex flex-col justify-between p-3.5 rounded-xl border border-border bg-foreground/[0.02] hover:bg-foreground/[0.05] hover:border-accent/40 text-left transition-all active:scale-[0.99] group cursor-pointer"
                  >
                    <div className="space-y-1.5">
                      <div className="flex items-center gap-2">
                        {isEpDiscussion ? (
                          <span className="font-mono text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded bg-accent/15 text-accent font-bold">
                            {isManga ? "Chapter Thread" : "Episode Thread"}
                          </span>
                        ) : (
                          <span className="font-mono text-[9px] uppercase tracking-wider px-1.5 py-0.5 rounded bg-foreground/[0.08] text-muted-foreground font-semibold">
                            Discussion
                          </span>
                        )}
                        <span className="text-[10px] font-mono text-muted-foreground/60 flex items-center gap-1">
                          <Clock size={10} />
                          {formatRelativeTime(thread.repliedAt || thread.createdAt)}
                        </span>
                      </div>

                      <h4 className="text-[13px] font-bold text-foreground group-hover:text-accent transition-colors line-clamp-2 leading-snug">
                        {thread.title}
                      </h4>
                    </div>

                    <div className="flex items-center justify-between pt-3 mt-2 border-t border-border/40 text-[11px] text-muted-foreground">
                      <div className="flex items-center gap-2">
                        {thread.user?.avatar?.medium ? (
                          <img
                            src={proxyImage(thread.user.avatar.medium)}
                            alt=""
                            className="w-4 h-4 rounded-full object-cover"
                          />
                        ) : (
                          <User size={12} className="text-muted-foreground" />
                        )}
                        <span className="font-medium truncate max-w-[120px]">
                          {thread.user?.name || "Anonymous"}
                        </span>
                      </div>

                      <div className="flex items-center gap-3 font-mono text-[10.5px]">
                        <span className="flex items-center gap-1 text-accent font-semibold">
                          <MessageSquare size={11} />
                          {thread.replyCount}
                        </span>
                        {thread.viewCount > 0 && (
                          <span className="flex items-center gap-1 text-muted-foreground/60">
                            <Eye size={11} />
                            {thread.viewCount}
                          </span>
                        )}
                      </div>
                    </div>
                  </button>
                );
              })}
            </div>
          )}
        </div>
      )}

      {/* Reviews Content */}
      {subTab === "reviews" && (
        <div className="space-y-4">
          {reviews.length === 0 ? (
            <div className="py-16 text-center text-xs text-muted-foreground">
              No user reviews written for this title yet.
            </div>
          ) : (
            <div className="space-y-3">
              {reviews.map((review) => {
                const isExpanded = expandedReviewId === review.id;
                return (
                  <div
                    key={review.id}
                    className="p-4 rounded-xl border border-border bg-foreground/[0.02] space-y-3 transition-colors hover:border-border/80"
                  >
                    <div className="flex items-start justify-between gap-4 flex-wrap">
                      <div className="flex items-center gap-2.5">
                        {review.user?.avatar?.medium ? (
                          <img
                            src={proxyImage(review.user.avatar.medium)}
                            alt=""
                            className="w-8 h-8 rounded-full object-cover border border-border"
                          />
                        ) : (
                          <div className="w-8 h-8 rounded-full bg-foreground/10 flex items-center justify-center">
                            <User size={16} />
                          </div>
                        )}
                        <div>
                          <div className="text-xs font-bold text-foreground">
                            {review.user?.name || "Reviewer"}
                          </div>
                          <div className="font-mono text-[10px] text-muted-foreground flex items-center gap-1">
                            <span>{formatRelativeTime(review.createdAt)}</span>
                            {review.ratingAmount > 0 && (
                              <>
                                <span>·</span>
                                <span className="flex items-center gap-1 text-emerald-400">
                                  <ThumbsUp size={10} />
                                  {review.rating} of {review.ratingAmount}
                                </span>
                              </>
                            )}
                          </div>
                        </div>
                      </div>

                      <div className="px-2.5 py-1 rounded-md bg-accent/15 border border-accent/30 text-accent font-mono font-bold text-xs flex items-center gap-1">
                        <Star size={12} fill="currentColor" />
                        <span>{review.score}%</span>
                      </div>
                    </div>

                    <h4 className="text-sm font-bold text-foreground leading-snug">
                      &ldquo;{review.summary}&rdquo;
                    </h4>

                    {isExpanded ? (
                      <div className="space-y-3 pt-1 border-t border-border/40">
                        <div
                          className="text-xs text-foreground/85 leading-relaxed prose-invert whitespace-pre-line"
                          dangerouslySetInnerHTML={{
                            __html: sanitizeHtml(review.body.replace(/\n/g, "<br />")),
                          }}
                        />
                        <button
                          onClick={() => setExpandedReviewId(null)}
                          className="text-xs text-accent font-semibold hover:underline cursor-pointer"
                        >
                          Show less
                        </button>
                      </div>
                    ) : (
                      <button
                        onClick={() => setExpandedReviewId(review.id)}
                        className="text-xs text-accent font-semibold hover:underline flex items-center gap-1 cursor-pointer"
                      >
                        <span>Read full review</span>
                        <ChevronRight size={12} />
                      </button>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}

      {/* Thread Reader Modal */}
      {selectedThreadId && (
        <div
          className="fixed inset-0 z-50 bg-black/75 backdrop-blur-sm flex items-center justify-center p-3 sm:p-6 animate-fade-in"
          onClick={() => setSelectedThreadId(null)}
        >
          <div
            className="w-full max-w-2xl max-h-[85vh] bg-surface rounded-2xl border border-border shadow-2xl flex flex-col overflow-hidden animate-scale-in"
            onClick={(e) => e.stopPropagation()}
          >
            {/* Thread Modal Header */}
            <div className="p-4 sm:p-5 border-b border-border flex items-start justify-between gap-4 bg-foreground/[0.02]">
              <div className="min-w-0 flex-1">
                <div className="flex items-center gap-2 font-mono text-[10px] uppercase tracking-wider text-muted-foreground pb-1">
                  <span className="text-accent font-bold">AniList Thread</span>
                  {threadDetail?.thread?.createdAt && (
                    <>
                      <span>·</span>
                      <span>{formatRelativeTime(threadDetail.thread.createdAt)}</span>
                    </>
                  )}
                </div>
                <h3 className="text-base sm:text-lg font-bold text-foreground leading-snug">
                  {threadDetail?.thread?.title || "Loading thread..."}
                </h3>
              </div>

              <button
                onClick={() => setSelectedThreadId(null)}
                className="p-1.5 rounded-lg text-muted-foreground hover:text-foreground hover:bg-foreground/10 transition-colors cursor-pointer"
                title="Close"
              >
                <X size={18} />
              </button>
            </div>

            {/* Thread Content & Comments Stream */}
            <div className="flex-1 overflow-y-auto p-4 sm:p-6 space-y-5">
              {loadingThread ? (
                <div className="py-16 flex flex-col items-center justify-center gap-3 text-muted-foreground">
                  <Loader2 className="animate-spin text-accent" size={24} />
                  <span className="text-xs font-mono">Loading thread comments...</span>
                </div>
              ) : (
                <>
                  {/* Original Post */}
                  {threadDetail?.thread?.body && (
                    <div className="p-4 rounded-xl bg-foreground/[0.03] border border-border space-y-2.5">
                      <div className="flex items-center gap-2">
                        {threadDetail.thread.user?.avatar?.medium ? (
                          <img
                            src={proxyImage(threadDetail.thread.user.avatar.medium)}
                            alt=""
                            className="w-5 h-5 rounded-full object-cover"
                          />
                        ) : (
                          <User size={13} className="text-muted-foreground" />
                        )}
                        <span className="text-xs font-bold text-foreground">
                          {threadDetail.thread.user?.name || "Original Poster"}
                        </span>
                      </div>
                      <CommentBody content={threadDetail.thread.body} />
                    </div>
                  )}

                  {/* Comments list */}
                  <div className="space-y-3 pt-2">
                    <div className="font-mono text-[11px] uppercase tracking-wider text-muted-foreground font-semibold flex items-center justify-between border-b border-border/40 pb-2">
                      <span>Comments ({threadDetail?.comments?.length || 0})</span>
                      <a
                        href={`https://anilist.co/forum/thread/${selectedThreadId}`}
                        target="_blank"
                        rel="noreferrer"
                        className="text-accent hover:underline flex items-center gap-1 text-[10px] normal-case font-sans font-medium"
                      >
                        <span>Open on AniList</span>
                        <ExternalLink size={10} />
                      </a>
                    </div>

                    {threadDetail?.comments?.length === 0 ? (
                      <p className="py-8 text-center text-xs text-muted-foreground">
                        No comments posted yet.
                      </p>
                    ) : (
                      <div className="space-y-3">
                        {threadDetail?.comments?.map((c) => (
                          <div
                            key={c.id}
                            className="p-3.5 rounded-xl bg-foreground/[0.02] border border-border/50 space-y-2"
                          >
                            <div className="flex items-center justify-between text-[11px]">
                              <div className="flex items-center gap-2">
                                {c.user?.avatar?.medium ? (
                                  <img
                                    src={proxyImage(c.user.avatar.medium)}
                                    alt=""
                                    className="w-5 h-5 rounded-full object-cover"
                                  />
                                ) : (
                                  <User size={13} className="text-muted-foreground" />
                                )}
                                <span className="font-bold text-foreground">
                                  {c.user?.name || "User"}
                                </span>
                                <span className="font-mono text-[10px] text-muted-foreground/60">
                                  {formatRelativeTime(c.createdAt)}
                                </span>
                              </div>

                              {c.likeCount > 0 && (
                                <span className="font-mono text-[10.5px] text-accent font-semibold flex items-center gap-1">
                                  <ThumbsUp size={11} />
                                  {c.likeCount}
                                </span>
                              )}
                            </div>

                            <CommentBody content={c.comment} />
                          </div>
                        ))}
                      </div>
                    )}
                  </div>
                </>
              )}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
