"use client";

import { useEffect, useRef, useCallback } from "react";
import { Loader2 } from "lucide-react";

interface InfiniteScrollProps {
  hasMore: boolean;
  loading: boolean;
  onLoadMore: () => void;
}

export default function InfiniteScroll({ hasMore, loading, onLoadMore }: InfiniteScrollProps) {
  const observerTarget = useRef(null);
  const onLoadMoreRef = useRef(onLoadMore);
  onLoadMoreRef.current = onLoadMore;

  useEffect(() => {
    const target = observerTarget.current;
    if (!target) return;

    const observer = new IntersectionObserver(
      entries => {
        if (entries[0].isIntersecting && hasMore && !loading) {
          onLoadMoreRef.current();
        }
      },
      { threshold: 0.1 }
    );

    observer.observe(target);

    return () => observer.disconnect();
  }, [hasMore, loading]);

  if (!hasMore) return null;

  return (
    <div ref={observerTarget} className="flex justify-center py-10">
      <Loader2 className="animate-spin text-accent" size={24} />
    </div>
  );
}
