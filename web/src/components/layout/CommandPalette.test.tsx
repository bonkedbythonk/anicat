import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { CommandPalette } from "./CommandPalette";
import { Sidebar } from "./Sidebar";
import { useAppStore } from "@/stores/app";
import { mediaApi } from "@/lib/api";
import { useKeyboardShortcuts } from "@/hooks/useKeyboardShortcuts";

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(() => Promise.resolve(() => {})),
}));

vi.mock("@/lib/platform", () => ({
  usesOverlayTitlebar: false,
  isMacOS: true,
  isWindows: false,
  isLinux: false,
}));

vi.mock("@/lib/api", () => ({
  mediaApi: {
    getUserList: vi.fn(() => Promise.resolve({ media: [] })),
    search: vi.fn(() => Promise.resolve({ media: [], page_info: null })),
    cinemaSearch: vi.fn(() => Promise.resolve({ media: [], page_info: null })),
  },
  getConfig: vi.fn(() => Promise.resolve({})),
}));

function Wrapper({ children }: { children: ReactNode }) {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: { retry: false },
    },
  });
  return <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>;
}

function ShortcutTestHarness() {
  useKeyboardShortcuts();
  return (
    <div>
      <Sidebar />
      <CommandPalette />
    </div>
  );
}

describe("CommandPalette", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    useAppStore.setState({
      paletteOpen: false,
      currentView: "home",
      selectedItem: null,
      apiAuthenticated: false,
      appMode: "anime",
      activeFocusScope: null,
    });
  });

  it("does not render when paletteOpen is false", () => {
    render(
      <Wrapper>
        <CommandPalette />
      </Wrapper>,
    );
    expect(screen.queryByRole("dialog", { name: "Command Palette" })).not.toBeInTheDocument();
  });

  it("renders floating modal with dark dimming scrim and search input with ESC badge", () => {
    useAppStore.setState({ paletteOpen: true });
    render(
      <Wrapper>
        <CommandPalette />
      </Wrapper>,
    );

    const dialog = screen.getByRole("dialog", { name: "Command Palette" });
    expect(dialog).toBeInTheDocument();
    expect(dialog).toHaveClass("fixed", "inset-0", "z-[300]", "bg-black/60");

    const input = screen.getByPlaceholderText("Search shows, actions, pages");
    expect(input).toBeInTheDocument();

    const escBadge = screen.getByText("ESC");
    expect(escBadge.tagName.toLowerCase()).toBe("kbd");
  });

  it("renders NAVIGATE section header in mono uppercase and all 8 navigation items", () => {
    useAppStore.setState({ paletteOpen: true });
    render(
      <Wrapper>
        <CommandPalette />
      </Wrapper>,
    );

    const navigateHeader = screen.getByText("NAVIGATE");
    expect(navigateHeader).toBeInTheDocument();
    expect(navigateHeader).toHaveClass("meta-mono");

    const expectedNavItems = [
      "Go to Up Next",
      "Go to Library",
      "Go to Schedule",
      "Go to Manga",
      "Go to Search",
      "Go to History",
      "Go to Downloads",
      "Go to Settings",
    ];

    expectedNavItems.forEach((label) => {
      expect(screen.getByRole("option", { name: new RegExp(label) })).toBeInTheDocument();
    });
  });

  it("navigates to target view and closes palette when a navigation item is clicked", async () => {
    useAppStore.setState({ paletteOpen: true, currentView: "home" });
    render(
      <Wrapper>
        <CommandPalette />
      </Wrapper>,
    );

    const settingsOption = screen.getByRole("option", { name: /Go to Settings/ });
    fireEvent.click(settingsOption);

    expect(useAppStore.getState().paletteOpen).toBe(false);
    expect(useAppStore.getState().currentView).toBe("settings");
    expect(useAppStore.getState().activeFocusScope).toBe("settings-default");
  });

  it("dismisses on pressing ESC key", () => {
    useAppStore.setState({ paletteOpen: true });
    render(
      <Wrapper>
        <CommandPalette />
      </Wrapper>,
    );

    expect(screen.getByRole("dialog", { name: "Command Palette" })).toBeInTheDocument();

    fireEvent.keyDown(document, { key: "Escape" });

    expect(useAppStore.getState().paletteOpen).toBe(false);
  });

  it("dismisses when clicking the dark dimming scrim backdrop", () => {
    useAppStore.setState({ paletteOpen: true });
    render(
      <Wrapper>
        <CommandPalette />
      </Wrapper>,
    );

    const scrim = screen.getByRole("dialog", { name: "Command Palette" });
    fireEvent.click(scrim);

    expect(useAppStore.getState().paletteOpen).toBe(false);
  });

  it("does not dismiss when clicking inside the modal content", () => {
    useAppStore.setState({ paletteOpen: true });
    render(
      <Wrapper>
        <CommandPalette />
      </Wrapper>,
    );

    const input = screen.getByPlaceholderText("Search shows, actions, pages");
    fireEvent.click(input);

    expect(useAppStore.getState().paletteOpen).toBe(true);
  });

  it("filters navigation items when typing in search input", async () => {
    useAppStore.setState({ paletteOpen: true });
    render(
      <Wrapper>
        <CommandPalette />
      </Wrapper>,
    );

    const input = screen.getByPlaceholderText("Search shows, actions, pages");
    fireEvent.change(input, { target: { value: "manga" } });

    expect(screen.getByRole("option", { name: /Go to Manga/ })).toBeInTheDocument();
    expect(screen.queryByRole("option", { name: /Go to Library/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("option", { name: /Go to Settings/ })).not.toBeInTheDocument();
  });

  it("shows 'No matches' when query matches nothing", () => {
    useAppStore.setState({ paletteOpen: true });
    render(
      <Wrapper>
        <CommandPalette />
      </Wrapper>,
    );

    const input = screen.getByPlaceholderText("Search shows, actions, pages");
    fireEvent.change(input, { target: { value: "zzzzz_nonexistent" } });

    expect(screen.getByText("No matches")).toBeInTheDocument();
  });

  it("searches shows when user types and opens detail upon selection", async () => {
    const mockShow = {
      id: 999,
      title: { english: "Frieren: Beyond Journey's End", romaji: "Sousou no Frieren" },
      cover_image: { large: "https://example.com/cover.jpg" },
    };
    vi.mocked(mediaApi.search).mockResolvedValueOnce({
      media: [mockShow as any],
      page_info: null,
    });

    useAppStore.setState({ paletteOpen: true, appMode: "anime" });
    const openDetailSpy = vi.fn();
    useAppStore.setState({ openDetail: openDetailSpy });

    render(
      <Wrapper>
        <CommandPalette />
      </Wrapper>,
    );

    const input = screen.getByPlaceholderText("Search shows, actions, pages");
    fireEvent.change(input, { target: { value: "Frieren" } });

    await waitFor(() => {
      expect(screen.getByText("Frieren: Beyond Journey's End")).toBeInTheDocument();
    });

    const showOption = screen.getByRole("option", { name: /Frieren: Beyond Journey's End/ });
    fireEvent.click(showOption);

    expect(useAppStore.getState().paletteOpen).toBe(false);
    expect(openDetailSpy).toHaveBeenCalledWith(expect.objectContaining({ id: 999 }));
  });

  it("triggers open globally via ⌘K and closes on ⌘K toggle", () => {
    render(
      <Wrapper>
        <ShortcutTestHarness />
      </Wrapper>,
    );

    expect(useAppStore.getState().paletteOpen).toBe(false);

    // Press Cmd+K to open
    fireEvent.keyDown(window, { key: "k", metaKey: true });
    expect(useAppStore.getState().paletteOpen).toBe(true);

    // Press Cmd+K again to toggle closed
    fireEvent.keyDown(window, { key: "k", metaKey: true });
    expect(useAppStore.getState().paletteOpen).toBe(false);
  });

  it("triggers open when clicking 'Search anything ⌘K' in the sidebar bottom", () => {
    render(
      <Wrapper>
        <ShortcutTestHarness />
      </Wrapper>,
    );

    expect(useAppStore.getState().paletteOpen).toBe(false);

    const searchButton = screen.getByRole("button", { name: /Search anything/ });
    fireEvent.click(searchButton);

    expect(useAppStore.getState().paletteOpen).toBe(true);
  });

  it("handles Enter in input to run top result", () => {
    useAppStore.setState({ paletteOpen: true, currentView: "home" });
    render(
      <Wrapper>
        <CommandPalette />
      </Wrapper>,
    );

    const input = screen.getByPlaceholderText("Search shows, actions, pages");
    input.focus();

    // Top item is "Go to Up Next" (view: "home")
    // Filter to "library" so top item is "Go to Library"
    fireEvent.change(input, { target: { value: "library" } });

    // Press Enter while in input
    fireEvent.keyDown(window, { key: "Enter" });

    expect(useAppStore.getState().paletteOpen).toBe(false);
    expect(useAppStore.getState().currentView).toBe("lists");
  });

  it("handles ArrowDown to focus list and ArrowUp from top to return focus to input", () => {
    useAppStore.setState({ paletteOpen: true });
    render(
      <Wrapper>
        <CommandPalette />
      </Wrapper>,
    );

    const input = screen.getByPlaceholderText("Search shows, actions, pages");
    input.focus();

    // Arrow down into the list
    fireEvent.keyDown(input, { key: "ArrowDown" });
    const firstOption = screen.getAllByRole("option")[0];
    expect(document.activeElement).toBe(firstOption);

    // Arrow up from first option back to input
    fireEvent.keyDown(firstOption, { key: "ArrowUp" });
    expect(document.activeElement).toBe(input);
  });

  it("displays library items with progress and resume action", async () => {
    const mockLibraryItem = {
      id: 42,
      title: { english: "Steins;Gate", romaji: "Steins;Gate" },
      episodes: 24,
      user_status: { status: "CURRENT", progress: 12 },
      cover_image: { large: "https://example.com/steins.jpg" },
    };

    useAppStore.setState({
      paletteOpen: true,
      apiAuthenticated: true,
      appMode: "anime",
    });

    const queryClient = new QueryClient();
    queryClient.setQueryData(["home-watching"], { media: [mockLibraryItem] });
    queryClient.setQueryData(["home-repeating"], { media: [] });
    queryClient.setQueryData(["home-planning"], { media: [] });

    render(
      <QueryClientProvider client={queryClient}>
        <CommandPalette />
      </QueryClientProvider>,
    );

    const input = screen.getByPlaceholderText("Search shows, actions, pages");
    fireEvent.change(input, { target: { value: "steins" } });

    expect(screen.getByText("YOUR LIBRARY")).toBeInTheDocument();
    expect(screen.getByText("Steins;Gate")).toBeInTheDocument();
    expect(screen.getByText("EP 13 / 24")).toBeInTheDocument();
    expect(screen.getByText("Resume Steins;Gate EP 13")).toBeInTheDocument();
  });

  it("searches cinema shows when in cinema mode", async () => {
    const mockMovie = {
      id: 550,
      title: { english: "Fight Club", romaji: "Fight Club" },
      cover_image: { large: "https://example.com/fc.jpg" },
    };
    vi.mocked(mediaApi.cinemaSearch).mockResolvedValueOnce({
      media: [mockMovie as any],
      page_info: null,
    });

    useAppStore.setState({ paletteOpen: true, appMode: "cinema" });

    render(
      <Wrapper>
        <CommandPalette />
      </Wrapper>,
    );

    const input = screen.getByPlaceholderText("Search shows, actions, pages");
    fireEvent.change(input, { target: { value: "Fight" } });

    await waitFor(() => {
      expect(screen.getByText("Fight Club")).toBeInTheDocument();
    });

    expect(screen.getByText("SHOWS")).toBeInTheDocument();
    expect(screen.getByText("Cinema")).toBeInTheDocument();
  });
});
