"use client";

import { useEffect, useState, useCallback } from "react";

export const REFRESH_EVENT = "anicat-refresh-data";

export function dispatchRefresh() {
  if (typeof window !== "undefined") {
    window.dispatchEvent(new CustomEvent(REFRESH_EVENT));
  }
}

export function useRefreshTrigger() {
  const [refreshKey, setRefreshKey] = useState(0);

  const handleRefresh = useCallback(() => {
    setRefreshKey((prev) => prev + 1);
  }, []);

  useEffect(() => {
    window.addEventListener(REFRESH_EVENT, handleRefresh);
    return () => window.removeEventListener(REFRESH_EVENT, handleRefresh);
  }, [handleRefresh]);

  return refreshKey;
}
