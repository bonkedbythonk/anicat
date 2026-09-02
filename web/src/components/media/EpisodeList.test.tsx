import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, act, fireEvent } from "@testing-library/react";

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(() => Promise.resolve(() => {})),
}));

vi.mock("@/lib/api", () => ({
  mediaApi: {
    preloadEpisode: vi.fn(() => Promise.resolve()),
    getPreloadStatus: vi.fn(() => Promise.resolve("idle")),
    getStreams: vi.fn(() => Promise.resolve({ streams: [] })),
    play: vi.fn(() => Promise.resolve()),
    addToQueue: vi.fn(() => Promise.resolve()),
    clearProviderCache: vi.fn(() => Promise.resolve()),
  },
}));

import { EpisodeList } from "./EpisodeList";
import { mediaApi } from "@/lib/api";
import { useAppStore } from "@/stores/app";

const MEDIA_ID = 12345;
const DELAY_MS = 400;

const episodes = [1, 2, 3].map((n) => ({ number: n, title: `Episode ${n}` })) as any;

function renderList(props: Record<string, unknown> = {}) {
  return render(
    <EpisodeList
      mediaId={MEDIA_ID}
      episodes={episodes}
      loading={false}
      progress={0}
      selectedProvider="nyaa"
      mediaTitle="Some Show"
      {...props}
    />,
  );
}

/** The play button of the nth episode row. Spatial navigation moves focus by
 *  calling `.focus()` on exactly this element, so focusing it is the same
 *  event path a keyboard user produces. */
function playButton(container: HTMLElement, index: number) {
  const rows = container.querySelectorAll(".episode-row-item");
  return rows[index].querySelector("button") as HTMLButtonElement;
}

describe("EpisodeList speculative preload", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.mocked(mediaApi.preloadEpisode).mockClear();
    useAppStore.setState({ preloadStatus: {} });
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("preloads the episode a settled hover is resting on", () => {
    const { container } = renderList();

    fireEvent.mouseOver(playButton(container, 1));
    act(() => {
      vi.advanceTimersByTime(DELAY_MS);
    });

    expect(mediaApi.preloadEpisode).toHaveBeenCalledTimes(1);
    expect(mediaApi.preloadEpisode).toHaveBeenCalledWith(MEDIA_ID, 2, "nyaa", "Some Show", true);
  });

  it("preloads on keyboard focus too", () => {
    const { container } = renderList();

    act(() => playButton(container, 2).focus());
    act(() => {
      vi.advanceTimersByTime(DELAY_MS);
    });

    expect(mediaApi.preloadEpisode).toHaveBeenCalledTimes(1);
    expect(mediaApi.preloadEpisode).toHaveBeenCalledWith(MEDIA_ID, 3, "nyaa", "Some Show", true);
  });

  it("cancels rather than queues when intent moves on before the delay", () => {
    const { container } = renderList();

    act(() => playButton(container, 0).focus());
    act(() => {
      vi.advanceTimersByTime(DELAY_MS - 100);
    });
    act(() => playButton(container, 1).focus());
    act(() => {
      vi.advanceTimersByTime(DELAY_MS);
    });

    expect(mediaApi.preloadEpisode).toHaveBeenCalledTimes(1);
    expect(mediaApi.preloadEpisode).toHaveBeenCalledWith(MEDIA_ID, 2, "nyaa", "Some Show", true);
  });

  it("keeps at most one speculative preload outstanding", () => {
    const { container } = renderList();

    act(() => playButton(container, 0).focus());
    act(() => {
      vi.advanceTimersByTime(DELAY_MS);
    });
    act(() => playButton(container, 1).focus());
    act(() => {
      vi.advanceTimersByTime(DELAY_MS);
    });

    expect(mediaApi.preloadEpisode).toHaveBeenCalledTimes(1);
    expect(mediaApi.preloadEpisode).toHaveBeenCalledWith(MEDIA_ID, 1, "nyaa", "Some Show", true);
  });

  it("skips an episode the backend is already fetching or holding", () => {
    useAppStore.getState().setPreloadStatus(MEDIA_ID, 2, "ready");
    const { container } = renderList();

    act(() => playButton(container, 1).focus());
    act(() => {
      vi.advanceTimersByTime(DELAY_MS);
    });

    expect(mediaApi.preloadEpisode).not.toHaveBeenCalled();
  });

  it("re-preloads an episode the backend has reported it no longer holds", () => {
    // The backend keeps one preloaded stream, so an episode marked ready can
    // lose the slot to a preload the user is likelier to play. That eviction
    // arrives as an `idle` event; before it existed the map sat on "ready"
    // forever and the guard above refused to warm an episode that was actually
    // cold -- a stuck wrong state rather than a missed preload.
    useAppStore.getState().setPreloadStatus(MEDIA_ID, 2, "ready");
    const { container } = renderList();

    act(() => useAppStore.getState().setPreloadStatus(MEDIA_ID, 2, "idle"));
    act(() => playButton(container, 1).focus());
    act(() => {
      vi.advanceTimersByTime(DELAY_MS);
    });

    expect(mediaApi.preloadEpisode).toHaveBeenCalledWith(MEDIA_ID, 2, "nyaa", "Some Show", true);
  });

  it("never preloads manga chapters", () => {
    const { container } = renderList({ isManga: true, onRead: () => {} });

    act(() => playButton(container, 1).focus());
    act(() => {
      vi.advanceTimersByTime(DELAY_MS);
    });

    expect(mediaApi.preloadEpisode).not.toHaveBeenCalled();
  });

  it("never preloads unaired episodes", () => {
    const { container } = renderList({ nextAiringEpisode: 2 });

    act(() => playButton(container, 2).focus());
    act(() => {
      vi.advanceTimersByTime(DELAY_MS);
    });

    expect(mediaApi.preloadEpisode).not.toHaveBeenCalled();
  });
});
