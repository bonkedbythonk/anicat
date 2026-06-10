import { StrictMode, Component, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { setQueryClient } from "@/lib/events";
import App from "./App";
import "./index.css";

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
      staleTime: 60_000,
      gcTime: 600_000,
      refetchOnWindowFocus: false,
      retry: 1,
    },
  },
});

setQueryClient(queryClient);

const root = document.getElementById("root");
if (!root) throw new Error("Root element not found");

createRoot(root).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <ErrorBoundary>
        <App />
      </ErrorBoundary>
    </QueryClientProvider>
  </StrictMode>,
);
