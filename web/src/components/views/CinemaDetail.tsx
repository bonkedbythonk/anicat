import { useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import {
  ArrowLeft,
  Bookmark,
  BookmarkCheck,
  Check,
  ChevronLeft,
  ChevronRight,
  Film,
  Loader2,
  Play,
  RotateCcw,
  X,
} from "lucide-react";
import { MediaRow } from "@/components/media/MediaRow";
import { getWatchHistory, mediaApi, type CinemaEpisode, type MediaItem } from "@/lib/api";
import { ChooseReleaseButton, CinemaReleasePicker } from "@/components/views/CinemaReleasePicker";
import { useFocusable, FocusScope } from "@/focus";
import { useModalDismiss } from "@/hooks/useModalDismiss";

/** The player's own rules for offering a resume, mirrored so the button never
 *  disagrees with what mpv will actually do: nothing under 30 seconds in, and
 *  nothing past the watched threshold, which is where an episode counts as
 *  finished rather than abandoned. Both live in `commands/playback.rs`. */
const MIN_RESUME_SECONDS = 30;
const WATCHED_THRESHOLD_PCT = 85;

interface WatchRow {
  episode_number: number;
  stop_time: number;
  duration: number;
}

function watchedFraction(row: WatchRow | undefined): number {
  if (!row || row.duration <= 0) return 0;
  return (row.stop_time / row.duration) * 100;
}

function isFinished(row: WatchRow | undefined): boolean {
  return watchedFraction(row) >= WATCHED_THRESHOLD_PCT;
}

function resumeSeconds(row: WatchRow | undefined): number {
  if (!row || row.duration <= 0) return 0;
  if (row.stop_time < MIN_RESUME_SECONDS || isFinished(row)) return 0;
  return row.stop_time;
}

function formatTimecode(seconds: number): string {
  const total = Math.floor(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
}

interface CinemaDetailProps {
  item: MediaItem;
  onClose: () => void;
  /** Opening a "More like this" title replaces this page with that one, the
   *  same way the anime detail page hops between related entries. */
  onSelect: (item: MediaItem) => void;
}

/** Cinema mode's detail page.
 *
 *  Deliberately separate from `MediaDetail` rather than a branch inside it.
 *  That component is wired end to end into the anime pipeline: opening it
 *  fires an AniList lookup, an episode scrape against anineko and nyaa, and a
 *  stream preload. Pointed at a film, every one of those is wrong, and the
 *  scrape and preload are not merely useless — they start real provider and
 *  torrent work for a title those providers will never have.
 *
 *  So this shows what TMDB knows and nothing more, and plays through the film
 *  or episode search rather than the anime one. */
export function CinemaDetail({ item, onClose, onSelect }: CinemaDetailProps) {
  const { ref, tabIndex } = useFocusable<HTMLButtonElement>();
  const { ref: playRef, tabIndex: playTabIndex } = useFocusable<HTMLButtonElement>();
  const [playing, setPlaying] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pickerOpen, setPickerOpen] = useState(false);
  const queryClient = useQueryClient();

  const library = useQuery({
    queryKey: ["cinema-library"],
    queryFn: () => mediaApi.cinemaLibrary(),
  });
  const entry = library.data?.find((e) => e.entry.media_id === item.id)?.entry;
  const onWatchlist = entry?.status === "PLANNING";

  const detail = useQuery({
    queryKey: ["media-detail", item.id],
    queryFn: () => mediaApi.getMediaDetail(item.id),
    staleTime: 60 * 60 * 1000,
  });

  // Position and duration per episode, from the local registry. Recorded for
  // cinema ids since the id bands landed; nothing was reading it.
  const history = useQuery({
    queryKey: ["watch-history", item.id],
    queryFn: () => getWatchHistory(item.id),
  });

  // The list entry we arrived with already carries a poster and a title, so
  // the page has something to show while the fuller record loads.
  const full = (detail.data as unknown as MediaItem) ?? item;
  const title = full.title?.english || full.title?.romaji || "";
  const year = full.season_year ?? full.seasonYear;
  const isSeries = full.format === "TV";

  // A film is its own single episode; the backend searches by title and year
  // rather than by episode number.
  // A film is one episode, so its whole watch state is that single row.
  const filmRow = history.data?.find((r) => r.episode_number === 1);
  const filmResume = resumeSeconds(filmRow);

  const handlePlay = async (startOver = false, server?: string) => {
    setPlaying(true);
    setError(null);
    try {
      await mediaApi.play(
        full.id,
        1,
        undefined,
        server,
        title,
        undefined,
        full.cover_image?.large,
        1,
        startOver,
      );
    } catch (e) {
      setError(
        typeof e === "string" && e.startsWith("No torrent found")
          ? "No release found for this one."
          : "Could not start playback. The log has the details.",
      );
    } finally {
      setPlaying(false);
    }
  };

  const facts: { label: string; value: string }[] = [];
  if (full.format) facts.push({ label: "Format", value: isSeries ? "Series" : "Film" });
  if (year) facts.push({ label: "Released", value: String(year) });
  if (isSeries && full.episodes) facts.push({ label: "Episodes", value: String(full.episodes) });
  if (full.duration) facts.push({ label: "Runtime", value: `${full.duration} min` });
  if (full.average_score ?? full.averageScore) {
    facts.push({ label: "Score", value: `${full.average_score ?? full.averageScore}%` });
  }
  if (full.status) facts.push({ label: "Status", value: full.status.replace(/_/g, " ").toLowerCase() });

  return (
    <FocusScope as="div" name="cinema-detail" orientation="vertical" className="min-h-screen">
      {full.banner_image && (
        <div className="relative h-[320px] w-full overflow-hidden">
          <img src={full.banner_image} alt="" className="h-full w-full object-cover" />
          <div className="absolute inset-0 bg-gradient-to-t from-background to-transparent" />
        </div>
      )}

      <div className={`px-10 pb-16 ${full.banner_image ? "-mt-24" : "pt-10"} relative`}>
        <button
          ref={ref}
          tabIndex={tabIndex}
          onClick={onClose}
          className="mb-6 flex cursor-pointer items-center gap-2 text-[13px] text-muted-foreground hover:text-foreground"
        >
          <ArrowLeft size={15} aria-hidden="true" />
          Back
        </button>

        <div className="flex flex-col gap-8 md:flex-row">
          {full.cover_image?.large && (
            <img
              src={full.cover_image.large}
              alt=""
              className="w-[200px] shrink-0 rounded-lg border border-border object-cover"
            />
          )}

          <div className="min-w-0 flex-1">
            <h1 className="text-[28px] font-semibold leading-tight text-foreground">{title}</h1>

            {full.tagline && (
              <p className="mt-1.5 text-[14px] italic text-muted-foreground">{full.tagline}</p>
            )}

            {facts.length > 0 && (
              <dl className="mt-4 flex flex-wrap gap-x-8 gap-y-3">
                {facts.map((f) => (
                  <div key={f.label}>
                    <dt className="meta-mono text-muted-foreground">{f.label}</dt>
                    <dd className="text-[13px] capitalize text-foreground">{f.value}</dd>
                  </div>
                ))}
              </dl>
            )}

            {full.genres?.length ? (
              <div className="mt-5 flex flex-wrap gap-2">
                {full.genres.map((g) => (
                  <span
                    key={g}
                    className="rounded-full border border-border px-2.5 py-1 text-[11px] text-muted-foreground"
                  >
                    {g}
                  </span>
                ))}
              </div>
            ) : null}

            {full.description && (
              <p className="mt-6 max-w-[70ch] text-[13px] leading-relaxed text-muted-foreground">
                {full.description}
              </p>
            )}

            {full.studio_names?.length ? (
              <p className="mt-4 text-[12px] text-muted-foreground">
                <span className="meta-mono">{isSeries ? "Network" : "Studio"}</span>{" "}
                {full.studio_names.slice(0, 3).join(", ")}
              </p>
            ) : null}

            {isSeries ? (
              <p className="mt-8 text-[12px] text-muted-foreground">
                Pick an episode below.
              </p>
            ) : (
              <div className="mt-8">
                <div className="flex flex-wrap items-center gap-3">
                  <button
                    ref={playRef}
                    tabIndex={playTabIndex}
                    onClick={() => handlePlay()}
                    disabled={playing}
                    className="flex cursor-pointer items-center gap-2 rounded-md bg-accent px-5 py-2.5 text-[13px] font-semibold text-background disabled:opacity-60"
                  >
                    {playing ? <Loader2 size={15} className="animate-spin" aria-hidden="true" /> : <Play size={15} aria-hidden="true" />}
                    {playing
                      ? "Finding a release"
                      : filmResume > 0
                        ? `Resume at ${formatTimecode(filmResume)}`
                        : isFinished(filmRow)
                          ? "Watch again"
                          : "Play"}
                  </button>

                  {/* Only worth offering when resuming is what the button
                      already does; otherwise it is the same action twice. */}
                  {filmResume > 0 && (
                    <button
                      onClick={() => handlePlay(true)}
                      disabled={playing}
                      className="flex cursor-pointer items-center gap-2 rounded-md border border-border px-4 py-2 text-[12px] text-muted-foreground hover:border-foreground/25 hover:text-foreground disabled:opacity-60"
                    >
                      <RotateCcw size={14} aria-hidden="true" />
                      Start over
                    </button>
                  )}

                  <ChooseReleaseButton onClick={() => setPickerOpen(true)} />
                </div>
                {error && <p className="mt-3 text-[12px] text-muted-foreground">{error}</p>}

                {pickerOpen && (
                  <CinemaReleasePicker
                    mediaId={full.id}
                    episodeNumber={1}
                    label={title}
                    onClose={() => setPickerOpen(false)}
                    onPick={(name) => {
                      setPickerOpen(false);
                      handlePlay(false, name);
                    }}
                  />
                )}
              </div>
            )}

            <div className="mt-4 flex flex-wrap gap-3">
              <button
                onClick={async () => {
                  if (onWatchlist) {
                    await mediaApi.cinemaRemoveFromLibrary(full.id);
                  } else {
                    await mediaApi.cinemaSetLibraryStatus(full.id, isSeries ? "TV" : "MOVIE", "PLANNING");
                  }
                  queryClient.invalidateQueries({ queryKey: ["cinema-library"], refetchType: "all" });
                }}
                className="flex cursor-pointer items-center gap-2 rounded-md border border-border px-4 py-2 text-[12px] text-muted-foreground hover:border-foreground/25 hover:text-foreground"
              >
                {onWatchlist ? (
                  <BookmarkCheck size={14} aria-hidden="true" />
                ) : (
                  <Bookmark size={14} aria-hidden="true" />
                )}
                {onWatchlist ? "On watchlist" : "Add to watchlist"}
              </button>
            </div>

            {full.trailer_id && (
              <button
                onClick={() => mediaApi.playTrailer(full.trailer_id!)}
                className="mt-3 flex cursor-pointer items-center gap-2 rounded-md border border-border px-4 py-2 text-[12px] text-muted-foreground hover:border-foreground/25 hover:text-foreground"
              >
                <Film size={14} aria-hidden="true" />
                Trailer
              </button>
            )}
          </div>
        </div>

        {full.gallery?.length ? <CinemaGallery images={full.gallery} title={title} /> : null}

        {isSeries && (
          <EpisodeList
            mediaId={full.id}
            title={title}
            cover={full.cover_image?.large}
            history={history.data ?? []}
          />
        )}

        {full.cast?.length ? (
          <section className="mt-14">
            <h2 className="meta-mono mb-4 text-muted-foreground">Cast</h2>
            <div className="flex gap-4 overflow-x-auto pb-2">
              {full.cast.map((person, i) => (
                <div key={person.id ?? i} className="w-[110px] shrink-0">
                  <div className="aspect-[2/3] overflow-hidden rounded-md border border-border bg-surface">
                    {person.photo && (
                      <img src={person.photo} alt="" className="h-full w-full object-cover" />
                    )}
                  </div>
                  <div className="mt-2 truncate text-[12px] font-medium text-foreground">
                    {person.name}
                  </div>
                  {person.character && (
                    <div className="truncate text-[11px] text-muted-foreground">{person.character}</div>
                  )}
                </div>
              ))}
            </div>
          </section>
        ) : null}

        {full.similar?.length ? (
          <section className="mt-14">
            <MediaRow title="More like this" items={full.similar} onSelect={onSelect} />
          </section>
        ) : null}
      </div>
    </FocusScope>
  );
}

/** The episode strip for a series.
 *
 *  Grouped by season for reading, but each row carries the absolute number,
 *  which is the identity the player, the watch history and auto-next all use.
 *  The season shown beside it is display only. */
function EpisodeList({
  mediaId,
  title,
  cover,
  history,
}: {
  mediaId: number;
  title: string;
  cover?: string;
  history: WatchRow[];
}) {
  const [playingEpisode, setPlayingEpisode] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);

  const episodes = useQuery({
    queryKey: ["cinema-episodes", mediaId],
    queryFn: () => mediaApi.cinemaEpisodes(mediaId),
    staleTime: 60 * 60 * 1000,
  });

  const [pickerFor, setPickerFor] = useState<CinemaEpisode | null>(null);

  const play = async (episode: CinemaEpisode, server?: string) => {
    setPlayingEpisode(episode.number);
    setError(null);
    try {
      await mediaApi.play(
        mediaId,
        episode.number,
        undefined,
        server,
        title,
        episode.title ?? undefined,
        cover,
        // The backend needs the count for two things, and both fail silently
        // without it: completion is `episode >= total`, so a series would
        // never leave Watching, and auto-next is bounded by `next > total`,
        // so after the finale it would try an episode that does not exist.
        episodes.data?.length,
      );
    } catch {
      setError(`Could not find a release for ${seasonLabel(episode)}.`);
    } finally {
      setPlayingEpisode(null);
    }
  };

  if (episodes.isLoading) {
    return (
      <div className="mt-12 flex justify-center py-10">
        <Loader2 className="animate-spin text-accent" size={24} />
      </div>
    );
  }
  if (episodes.isError || !episodes.data?.length) {
    return (
      <p className="mt-12 text-[13px] text-muted-foreground">No episode list available for this one.</p>
    );
  }

  const rowFor = (episode: CinemaEpisode) =>
    history.find((r) => r.episode_number === episode.number);

  // Where to pick up: the first episode that is neither finished nor past. A
  // part-watched episode wins over the next unstarted one, since that is what
  // "continue" means to someone who stopped halfway.
  const partWatched = episodes.data.find((e) => resumeSeconds(rowFor(e)) > 0);
  const nextUnwatched = episodes.data.find((e) => !isFinished(rowFor(e)));
  const continueAt = partWatched ?? nextUnwatched;

  const bySeason = new Map<number, CinemaEpisode[]>();
  for (const episode of episodes.data) {
    const season = episode.season ?? 1;
    if (!bySeason.has(season)) bySeason.set(season, []);
    bySeason.get(season)!.push(episode);
  }

  return (
    <div className="mt-12 space-y-10">
      {error && <p className="text-[12px] text-muted-foreground">{error}</p>}

      {continueAt && (
        <button
          onClick={() => play(continueAt)}
          disabled={playingEpisode !== null}
          className="flex cursor-pointer items-center gap-2 rounded-md bg-accent px-5 py-2.5 text-[13px] font-semibold text-background disabled:opacity-60"
        >
          {playingEpisode !== null ? (
            <Loader2 size={15} className="animate-spin" aria-hidden="true" />
          ) : (
            <Play size={15} aria-hidden="true" />
          )}
          {resumeSeconds(rowFor(continueAt)) > 0
            ? `Resume ${seasonLabel(continueAt)} at ${formatTimecode(resumeSeconds(rowFor(continueAt)))}`
            : `Play ${seasonLabel(continueAt)}`}
        </button>
      )}
      {[...bySeason.entries()].map(([season, list]) => (
        <section key={season}>
          <h2 className="meta-mono mb-4 text-muted-foreground">Season {season}</h2>
          <div className="space-y-2">
            {list.map((episode) => (
              <EpisodeRow
                key={episode.number}
                episode={episode}
                busy={playingEpisode === episode.number}
                watch={rowFor(episode)}
                onPlay={() => play(episode)}
                onChooseRelease={() => setPickerFor(episode)}
              />
            ))}
          </div>
        </section>
      ))}

      {pickerFor && (
        <CinemaReleasePicker
          mediaId={mediaId}
          episodeNumber={pickerFor.number}
          label={seasonLabel(pickerFor)}
          onClose={() => setPickerFor(null)}
          onPick={(name) => {
            const episode = pickerFor;
            setPickerFor(null);
            play(episode, name);
          }}
        />
      )}
    </div>
  );
}

/** Backdrops and key art, so the visual style reads at a glance without
 *  starting the trailer. First thing after the synopsis: for a title
 *  arriving cold with no history of your own to warm up the page, this is
 *  most of the first impression. No spoiler gating, unlike the anime
 *  gallery's episode stills -- backdrops and posters are marketing art, never
 *  a scene from later in the story. */
function CinemaGallery({ images, title }: { images: string[]; title: string }) {
  const [lightbox, setLightbox] = useState<number | null>(null);

  return (
    <section className="mt-14">
      <h2 className="meta-mono mb-4 text-muted-foreground">Gallery</h2>
      <div className="flex gap-3 overflow-x-auto pb-2">
        {images.map((src, i) => (
          <button
            key={src}
            onClick={() => setLightbox(i)}
            aria-label={`View image ${i + 1} of ${images.length}`}
            className="aspect-video w-[260px] shrink-0 cursor-pointer overflow-hidden rounded-md border border-border bg-surface hover:border-foreground/25"
          >
            <img src={src} alt="" loading="lazy" className="h-full w-full object-cover" />
          </button>
        ))}
      </div>

      {lightbox !== null && (
        <CinemaLightbox
          images={images}
          index={lightbox}
          title={title}
          onClose={() => setLightbox(null)}
          onIndexChange={setLightbox}
        />
      )}
    </section>
  );
}

function CinemaLightbox({
  images,
  index,
  title,
  onClose,
  onIndexChange,
}: {
  images: string[];
  index: number;
  title: string;
  onClose: () => void;
  onIndexChange: (next: number) => void;
}) {
  const dialogRef = useModalDismiss<HTMLDivElement>(true, onClose);

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === "ArrowRight") {
        e.preventDefault();
        onIndexChange((index + 1) % images.length);
      } else if (e.key === "ArrowLeft") {
        e.preventDefault();
        onIndexChange((index - 1 + images.length) % images.length);
      }
    };
    document.addEventListener("keydown", onKeyDown, true);
    return () => document.removeEventListener("keydown", onKeyDown, true);
  }, [index, images.length, onIndexChange]);

  return (
    <div
      ref={dialogRef}
      role="dialog"
      aria-modal="true"
      aria-label={`${title} — image ${index + 1} of ${images.length}`}
      tabIndex={-1}
      className="fixed inset-0 z-[300] flex items-center justify-center bg-black/90 p-6"
      onClick={onClose}
    >
      <button
        onClick={onClose}
        aria-label="Close"
        className="absolute right-5 top-5 cursor-pointer rounded-md bg-foreground/10 p-2.5 text-foreground hover:bg-foreground/20"
      >
        <X size={18} />
      </button>

      {images.length > 1 && (
        <button
          onClick={(e) => {
            e.stopPropagation();
            onIndexChange((index - 1 + images.length) % images.length);
          }}
          aria-label="Previous image"
          className="absolute left-4 cursor-pointer rounded-md bg-foreground/10 p-3 text-foreground hover:bg-foreground/20"
        >
          <ChevronLeft size={20} aria-hidden="true" />
        </button>
      )}

      <img
        src={images[index]}
        alt=""
        onClick={(e) => e.stopPropagation()}
        className="max-h-[80vh] w-auto max-w-full rounded-md object-contain shadow-2xl"
      />

      {images.length > 1 && (
        <button
          onClick={(e) => {
            e.stopPropagation();
            onIndexChange((index + 1) % images.length);
          }}
          aria-label="Next image"
          className="absolute right-4 cursor-pointer rounded-md bg-foreground/10 p-3 text-foreground hover:bg-foreground/20"
        >
          <ChevronRight size={20} aria-hidden="true" />
        </button>
      )}

      <p className="absolute bottom-5 text-[11px] text-foreground/60">
        {index + 1} / {images.length}
      </p>
    </div>
  );
}

function seasonLabel(episode: CinemaEpisode): string {
  const season = String(episode.season ?? 1).padStart(2, "0");
  const number = String(episode.episode_in_season ?? episode.number).padStart(2, "0");
  return `S${season}E${number}`;
}

function EpisodeRow({
  episode,
  busy,
  watch,
  onPlay,
  onChooseRelease,
}: {
  episode: CinemaEpisode;
  busy: boolean;
  watch: WatchRow | undefined;
  onPlay: () => void;
  onChooseRelease: () => void;
}) {
  const { ref, tabIndex } = useFocusable<HTMLButtonElement>();
  const finished = isFinished(watch);
  const resume = resumeSeconds(watch);
  const fraction = watchedFraction(watch);
  return (
    <div className="group flex items-center gap-2">
    <button
      ref={ref}
      tabIndex={tabIndex}
      onClick={onPlay}
      disabled={busy}
      aria-label={`${resume > 0 ? "Resume" : "Play"} ${seasonLabel(episode)}${
        episode.title ? `, ${episode.title}` : ""
      }${finished ? ", watched" : ""}`}
      className="flex min-w-0 flex-1 cursor-pointer items-center gap-4 rounded-md border border-border p-3 text-left hover:border-foreground/25 disabled:opacity-60"
    >
      <div className="relative aspect-video w-[140px] shrink-0 overflow-hidden rounded bg-surface">
        {episode.thumbnail && (
          <img src={episode.thumbnail} alt="" className="h-full w-full object-cover" />
        )}
        <div className="absolute inset-0 flex items-center justify-center bg-black/40 opacity-0 transition-opacity group-hover:opacity-100 group-focus-visible:opacity-100">
          {busy ? (
            <Loader2 size={18} className="animate-spin text-white" aria-hidden="true" />
          ) : (
            <Play size={18} className="text-white" aria-hidden="true" />
          )}
        </div>

        {/* How far in, for an episode left partway. Drawn on the thumbnail
            rather than in the text so it reads at a glance down the list. */}
        {resume > 0 && (
          <div className="absolute bottom-0 left-0 right-0 h-[3px] bg-black/50">
            <div className="h-full bg-accent" style={{ width: `${Math.min(fraction, 100)}%` }} />
          </div>
        )}
      </div>

      <div className="min-w-0 flex-1">
        <div className="flex items-baseline gap-2">
          <span className="meta-mono text-muted-foreground">{seasonLabel(episode)}</span>
          {finished && (
            <span
              aria-hidden="true"
              className="inline-flex items-center gap-1 text-[11px] text-accent"
            >
              <Check size={12} />
              Watched
            </span>
          )}
          {resume > 0 && (
            <span aria-hidden="true" className="meta-mono text-accent">
              {formatTimecode(resume)}
            </span>
          )}
          {episode.duration ? (
            <span className="meta-mono text-muted-foreground">{episode.duration} min</span>
          ) : null}
        </div>
        <div className={`mt-0.5 truncate text-[13px] font-medium ${finished ? "text-foreground/60" : "text-foreground"}`}>
          {episode.title || `Episode ${episode.episode_in_season ?? episode.number}`}
        </div>
        {episode.description && (
          <p className="mt-1 line-clamp-2 text-[12px] leading-relaxed text-muted-foreground">
            {episode.description}
          </p>
        )}
      </div>
    </button>
      <div className="opacity-0 transition-opacity group-hover:opacity-100 group-focus-within:opacity-100">
        <ChooseReleaseButton onClick={onChooseRelease} />
      </div>
    </div>
  );
}
