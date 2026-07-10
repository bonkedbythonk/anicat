import { Component, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { persistQueryClient } from "@tanstack/react-query-persist-client";
import { createSyncStoragePersister } from "@tanstack/query-sync-storage-persister";
import { setQueryClient } from "@/lib/events";
import MobileApp from "./MobileApp";
import "../index.css";

document.documentElement.classList.add("dark");

class ErrorBoundary extends Component<{ children: ReactNode }> {
  state = { error: null };
  static getDerivedStateFromError(error: unknown) { return { error }; }
  render() {
    if (this.state.error) {
      return (
        <div className="flex h-screen items-center justify-center bg-[#050505] text-white flex-col gap-4 p-8">
          <h1 className="text-xl font-bold">Something went wrong</h1>
          <p className="text-gray-400 text-sm text-center max-w-md">
            {(this.state.error as Error)?.message || "An unexpected error occurred"}
          </p>
          <button
            onClick={() => { this.setState({ error: null }); window.location.reload(); }}
            className="px-4 py-2 rounded-lg bg-accent text-white text-sm hover:bg-accent-hover transition-colors"
          >
            Reload
          </button>
        </div>
      );
    }
    return this.props.children;
  }
}

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 5 * 60 * 1000,
      gcTime: 24 * 60 * 60 * 1000,
      // Desktop turns this off since alt-tabbing back to a multi-window app
      // is frequent and not a meaningful "check for updates" signal. On a
      // phone PWA, refocusing (switching back from the home screen or
      // another app) is a deliberate return — and it's the only signal this
      // surface gets that something might have changed on desktop meanwhile
      // (there's no push channel between the two; each holds its own cache).
      refetchOnWindowFocus: true,
      retry: 1,
    },
  },
});

setQueryClient(queryClient);

const persister = createSyncStoragePersister({
  storage: window.localStorage,
  key: "anicat-mobile-query-cache",
  throttleTime: 2000,
});

persistQueryClient({
  queryClient,
  persister,
  maxAge: 24 * 60 * 60 * 1000,
  buster: "v3",
});

const root = document.getElementById("root");
if (!root) throw new Error("Root element not found");

createRoot(root).render(
  <QueryClientProvider client={queryClient}>
    <ErrorBoundary>
      <MobileApp />
    </ErrorBoundary>
  </QueryClientProvider>,
);
