import { useContext, useEffect, useMemo, useRef, useState, type RefObject } from "react";
import { useQuery } from "@tanstack/react-query";
import { Loader2 } from "lucide-react";
import { mediaApi, type MediaItem } from "@/lib/api";
import { proxyImage } from "@/lib/proxy";
import { useAppStore } from "@/stores/app";
import { FocusScope, useFocusable } from "@/focus";
import { useModalDismiss } from "@/hooks/useModalDismiss";
import { FocusContext } from "@/focus/FocusScope";
import type { ViewType } from "@/lib/types";

interface PaletteRow {
  kind: "library" | "anilist" | "nav" | "action";
  key: string;
  label: string;
  hint?: string;
  cover?: string;
  run: () => void;
}

const NAV_TARGETS: { label: string; view: ViewType }[] = [
  { label: "Go to Up Next", view: "home" },
  { label: "Go to Library", view: "lists" },
  { label: "Go to Schedule", view: "schedule" },
  { label: "Go to Manga", view: "manga" },
  { label: "Go to Search", view: "search" },
  { label: "Go to History", view: "profile" },
  { label: "Go to Downloads", view: "downloads" },
  { label: "Go to Settings", view: "settings" },
];

function PaletteRowButton({ row }: { row: PaletteRow }) {
  const { ref, isFocused, tabIndex } = useFocusable<HTMLButtonElement>();

  return (
    <button
      ref={ref}
      tabIndex={tabIndex}
      onClick={row.run}
      onMouseMove={() => ref.current?.focus()}
      className={`w-full flex items-center gap-3 px-2.5 py-2 rounded-md text-left cursor-pointer ${
        isFocused ? "bg-accent/12 text-foreground" : "text-foreground/60"
      }`}
    >
      {row.cover && (
        <img src={proxyImage(row.cover)} alt="" className="w-6 h-8 rounded-sm object-cover shrink-0" />
      )}
      <span className="flex-1 truncate text-[13px]">{row.label}</span>
      {row.hint && <span className="meta-mono text-muted-foreground shrink-0">{row.hint}</span>}
    </button>
  );
}

function PaletteResults({
  rows,
  query,
  inputRef,
}: {
  rows: PaletteRow[];
  query: string;
  inputRef: RefObject<HTMLInputElement | null>;
}) {
  const scope = useContext(FocusContext);

  useEffect(() => {
    if (!scope) return;
    const handler = (e: KeyboardEvent) => {
      const inputFocused = document.activeElement === inputRef.current;
      if (e.key === "ArrowDown") {
        e.preventDefault();
        if (inputFocused) {
          scope.focusFirst();
        } else {
          scope.focusNext();
        }
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        if (inputFocused) {
          scope.focusLast();
        } else {
          scope.focusPrev();
        }
      } else if (e.key === "Enter") {
        e.preventDefault();
        const index = inputFocused ? 0 : scope.activeIndex;
        rows[index]?.run();
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [rows, scope, inputRef]);

  const sections: { title: string; rows: PaletteRow[] }[] = [];
  rows.forEach((row) => {
    const title =
      row.kind === "library" || row.kind === "action"
        ? "Your library"
        : row.kind === "nav"
          ? "Navigate"
          : "AniList";
    const section = sections.find((s) => s.title === title);
    if (section) section.rows.push(row);
    else sections.push({ title, rows: [row] });
  });

  return (
    <>
      {sections.length === 0 && (
        <p className="meta-mono px-4 py-6 text-muted-foreground text-center">
          {query ? "No matches" : "Type to search"}
        </p>
      )}
      {sections.map((section) => (
        <div key={section.title} className="px-1.5 pb-1">
          <div className="meta-mono px-2.5 pt-2 pb-1 text-muted-foreground/70 select-none">{section.title}</div>
          {section.rows.map((row) => (
            <PaletteRowButton key={row.key} row={row} />
          ))}
        </div>
      ))}
    </>
  );
}

/** Cmd-K: one palette for everything. Library matches first (they're what
 * you almost always want), then actions on the top match, then AniList for
 * things not in your library yet. */
export function CommandPalette() {
  const open = useAppStore((s) => s.paletteOpen);
  const setOpen = useAppStore((s) => s.setPaletteOpen);
  const openDetail = useAppStore((s) => s.openDetail);
  const closeDetail = useAppStore((s) => s.closeDetail);
  const setCurrentView = useAppStore((s) => s.setCurrentView);
  const isAuthenticated = useAppStore((s) => s.apiAuthenticated);
  const activeFocusScope = useAppStore((s) => s.activeFocusScope);
  const setActiveFocusScope = useAppStore((s) => s.setActiveFocusScope);

  const [query, setQuery] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  const previousScopeRef = useRef<string | null>(null);

  // Library pool: watching + repeating + planning (the lists you actually
  // jump to). Shares query keys with the home view, so usually cache-warm.
  const watchingQ = useQuery({
    queryKey: ["home-watching"],
    queryFn: () => mediaApi.getUserList("watching", "ANIME"),
    enabled: open && isAuthenticated,
  });
  const repeatingQ = useQuery({
    queryKey: ["home-repeating"],
    queryFn: () => mediaApi.getUserList("repeating", "ANIME"),
    enabled: open && isAuthenticated,
  });
  const planningQ = useQuery({
    queryKey: ["home-planning"],
    queryFn: () => mediaApi.getUserList("planning", "ANIME"),
    enabled: open && isAuthenticated,
  });

  const [debounced, setDebounced] = useState("");
  useEffect(() => {
    const t = setTimeout(() => setDebounced(query.trim()), 250);
    return () => clearTimeout(t);
  }, [query]);

  const anilistQ = useQuery({
    queryKey: ["palette-search", debounced],
    queryFn: () => mediaApi.search(debounced, "ANIME", 1, {}),
    enabled: open && debounced.length >= 3,
    staleTime: 60_000,
  });

  const close = () => {
    setOpen(false);
    setQuery("");
  };

  const rows = useMemo<PaletteRow[]>(() => {
    const q = query.trim().toLowerCase();
    const out: PaletteRow[] = [];

    const libraryPool: MediaItem[] = [
      ...(watchingQ.data?.media || []),
      ...(repeatingQ.data?.media || []),
      ...(planningQ.data?.media || []),
    ];
    const seen = new Set<number>();
    const libMatches = libraryPool.filter((m) => {
      if (seen.has(m.id)) return false;
      seen.add(m.id);
      if (!q) return false;
      const names = [m.title.english, m.title.romaji, m.title.native].filter(Boolean) as string[];
      return names.some((n) => n.toLowerCase().includes(q));
    }).slice(0, 5);

    for (const m of libMatches) {
      const progress = m.user_status?.progress ?? m.media_list_entry?.progress ?? 0;
      const total = m.episodes || 0;
      out.push({
        kind: "library",
        key: `lib-${m.id}`,
        label: m.title.english || m.title.romaji || "",
        hint: `EP ${progress + 1}${total ? ` / ${total}` : ""}`,
        cover: m.cover_image?.medium || m.cover_image?.large,
        run: () => {
          close();
          openDetail(m);
        },
      });
      if (out.length === 1) {
        out.push({
          kind: "action",
          key: `play-${m.id}`,
          label: `Resume ${m.title.english || m.title.romaji} EP ${progress + 1}`,
          hint: "Enter",
          run: () => {
            close();
            openDetail(m, "play");
          },
        });
      }
    }

    for (const nav of NAV_TARGETS) {
      if (!q || nav.label.toLowerCase().includes(q)) {
        out.push({
          kind: "nav",
          key: `nav-${nav.view}`,
          label: nav.label,
          run: () => {
            close();
            closeDetail();
            setCurrentView(nav.view);
          },
        });
      }
    }

    const libIds = new Set(libraryPool.map((m) => m.id));
    for (const m of (anilistQ.data?.media || []).filter((m: MediaItem) => !libIds.has(m.id)).slice(0, 5)) {
      out.push({
        kind: "anilist",
        key: `al-${m.id}`,
        label: m.title.english || m.title.romaji || "",
        hint: "AniList",
        cover: m.cover_image?.medium || m.cover_image?.large,
        run: () => {
          close();
          openDetail(m);
        },
      });
    }

    return out;
  }, [query, watchingQ.data, repeatingQ.data, planningQ.data, anilistQ.data]);

  useEffect(() => {
    if (!open) return;
    previousScopeRef.current = activeFocusScope;
    setActiveFocusScope("command-palette");
    const t = setTimeout(() => inputRef.current?.focus(), 30);
    return () => {
      clearTimeout(t);
      setActiveFocusScope(previousScopeRef.current);
    };
  }, [open]);


  const modalRef = useModalDismiss<HTMLDivElement>(open, close);


  if (!open) return null;

  return (
    <div
      ref={modalRef}
      className="fixed inset-0 z-[300] bg-black/50 flex items-start justify-center pt-[14vh]"
      onClick={close}
      role="dialog"
      aria-modal="true"
      aria-label="Command Palette"
      tabIndex={-1}
    >
      <div
        className="w-[min(560px,92vw)] rounded-lg border border-border bg-surface shadow-2xl shadow-black/50 overflow-hidden animate-fade-in-fast"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center gap-3 px-4 py-3 border-b border-border">
          <input
            ref={inputRef}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search shows, actions, pages"
            className="flex-1 bg-transparent px-2 py-1 text-[14px] text-foreground placeholder:text-muted-foreground outline-none border-none shadow-none focus:ring-0 focus-visible:shadow-none"
          />
          {anilistQ.isFetching && <Loader2 size={14} className="animate-spin text-muted-foreground" />}
          <kbd className="meta-mono text-[9px] text-muted-foreground border border-border rounded px-1.5 py-0.5">Esc</kbd>
        </div>
        <FocusScope
          name="command-palette-list"
          orientation="vertical"
          role="listbox"
          className="max-h-[46vh] overflow-y-auto py-1.5"
        >
          <PaletteResults rows={rows} query={query} inputRef={inputRef} />
        </FocusScope>
      </div>
    </div>
  );
}
