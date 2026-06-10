"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { AppStateProvider } from "@/lib/AppStateContext";
import { ToastProvider } from "@/components/shared/Toast";
import { useState } from "react";

/**
 * Module-level reference to the singleton QueryClient so non-React
 * code (health polling, events) can invalidate caches directly.
 * Access via `getQueryClient()` — never read directly in SSR contexts.
 */
let _queryClient: QueryClient | undefined;

export function getQueryClient(): QueryClient | undefined {
  return _queryClient;
}

export default function Providers({ children }: { children: React.ReactNode }) {
  const [qc] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: {
            staleTime: 60 * 1000,
            gcTime: 10 * 60 * 1000,
            refetchOnWindowFocus: false,
          },
        },
      })
  );

  // Publish singleton for external invalidation
  _queryClient = qc;

  return (
    <QueryClientProvider client={qc}>
      <AppStateProvider>
        <ToastProvider>
          {children}
        </ToastProvider>
      </AppStateProvider>
    </QueryClientProvider>
  );
}
