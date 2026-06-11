import { useEffect, useRef, type ReactNode } from "react";
export function InfiniteScroll({ children, onLoadMore, hasMore, loading }: { children: ReactNode; onLoadMore: () => void; hasMore: boolean; loading?: boolean }) {
  const loadMore = onLoadMore;
  const sentinel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = sentinel.current;
    if (!el) return;
    const obs = new IntersectionObserver(([e]) => { if (e.isIntersecting && hasMore) loadMore(); });
    obs.observe(el);
    return () => obs.disconnect();
  }, [loadMore, hasMore]);
  return <>{children}<div ref={sentinel} /></>;
}
