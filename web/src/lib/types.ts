export type ViewType =
  | "home"
  | "manga"
  | "search"
  | "lists"
  | "schedule"
  | "notifications"
  | "profile"
  | "settings"
  | "downloads";

export interface MediaTitle {
  romaji?: string;
  english?: string;
  native?: string;
}

export interface MediaCoverImage {
  large?: string;
  medium?: string;
  extraLarge?: string;
}

export interface MediaItem {
  id: number;
  id_mal?: number;
  type?: "ANIME" | "MANGA";
  title: MediaTitle;
  coverImage: MediaCoverImage;
  cover_image?: MediaCoverImage;
  bannerImage?: string;
  banner_image?: string;
  description?: string;
  format?: string;
  status?: string;
  season?: string;
  seasonYear?: number;
  episodes?: number;
  duration?: number;
  chapters?: number;
  volumes?: number;
  genres?: string[];
  averageScore?: number;
  average_score?: number;
  meanScore?: number;
  popularity?: number;
  favourites?: number;
  is_favourite?: boolean;
  trending?: number;
  user_status?: {
    id?: number;
    status?: string;
    progress?: number;
    progress_volumes?: number | null;
    score?: number;
    updated_at?: string | null;
  };
  media_list_entry?: {
    id: number;
    status: string;
    score: number;
    progress: number;
    progress_volumes?: number;
    repeat: number;
    private: boolean;
    notes?: string;
    started_at?: { year?: number; month?: number; day?: number };
    completed_at?: { year?: number; month?: number; day?: number };
    updated_at?: string | null;
  };
  studios?: {
    nodes?: { name: string; isAnimationStudio?: boolean }[];
  };
  season_year?: number;
  startDate?: { year?: number; month?: number; day?: number };
  endDate?: { year?: number; month?: number; day?: number };
  end_date?: string;
  nextAiringEpisode?: {
    airingAt?: number;
    episode?: number;
    timeUntilAiring?: number;
    airing_at?: string | number;
  };
  next_airing?: {
    episode?: number;
    airing_at?: string | number;
  };
  trailer?: {
    id?: string;
    site?: string;
    thumbnail?: string;
    thumbnail_url?: string;
  };
  tags?: { name: string; rank: number }[];
  relations?: {
    edges?: {
      relationType: string;
      node: MediaItem;
    }[];
  };
  recommendations?: {
    nodes?: {
      mediaRecommendation?: MediaItem;
      // flat shape returned after snakify
      id?: number;
      title?: MediaTitle;
      coverImage?: MediaCoverImage;
      cover_image?: MediaCoverImage;
      type?: "ANIME" | "MANGA";
      format?: string;
    }[];
  };
  streaming_episodes?: { title?: string; thumbnail?: string }[];
  characters?: {
    edges?: {
      role: string;
      node: {
        id: number;
        name: { full: string };
        image: { large?: string };
      };
      voiceActors?: {
        id: number;
        name: { full: string };
        image: { large?: string };
        language: string;
      }[];
    }[];
  };
  autoplay_trailers?: boolean;
  mediaListEntry?: {
    id: number;
    status: string;
    score: number;
    progress: number;
    progressVolumes?: number;
    repeat: number;
    private: boolean;
    notes?: string;
    startedAt?: { year?: number; month?: number; day?: number };
    completedAt?: { year?: number; month?: number; day?: number };
  };
  playlist_reason?: string;
  relation_type?: string;
  siteUrl?: string;
}

export interface Episode {
  number: string | number;
  title?: string;
  image?: string;
  description?: string;
  filler?: boolean;
  download_status?: string;
  is_downloaded?: boolean;
}

export interface StreamServer {
  name: string;
  url: string;
  quality?: string;
  isM3U8?: boolean;
  headers?: Record<string, string>;
  group?: string;
  /** Torrent releases only — swarm health, shown in the picker. */
  seeders?: number;
}

export interface Character {
  id: number;
  name: { full: string; native?: string };
  image?: { large?: string };
  description?: string;
  role?: string;
  voiceActors?: {
    id: number;
    name: { full: string };
    image: { large?: string };
    language: string;
  }[];
}

export interface Review {
  id?: number;
  summary?: string;
  body: string;
  score?: number;
  rating?: number;
  user: {
    id?: number;
    name: string;
    avatar?: string;
    avatar_url?: string;
  };
}

export interface SmartPlaylistItem {
  media: MediaItem;
  reason: string;
}

export interface SearchFilter {
  genre?: string[];
  year?: number;
  season?: string;
  format?: string;
  status?: string;
  sort?: string;
}

export interface AiringSchedule {
  id: number;
  episode: number;
  airingAt: number;
  media: MediaItem;
}

export interface Notification {
  id: number;
  type: string;
  episode?: number;
  contexts?: string[];
  media?: MediaItem;
  createdAt: number;
}

export interface UserProfile {
  id: number;
  name: string;
  about?: string;
  avatar?: { large?: string; medium?: string };
  bannerImage?: string;
  statistics?: {
    anime?: {
      count: number;
      meanScore: number;
      minutesWatched: number;
      episodesWatched: number;
    };
  };
}

export interface ListEntry {
  media: MediaItem;
  status: string;
  score: number;
  progress: number;
}
