export type ViewType =
  | "home"
  | "search"
  | "library"
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
}

export interface MediaItem {
  id: number;
  type: "ANIME" | "MANGA";
  title: MediaTitle;
  coverImage: MediaCoverImage;
  bannerImage?: string;
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
  meanScore?: number;
  popularity?: number;
  favourites?: number;
  trending?: number;
  studios?: { nodes?: { name: string }[] };
  startDate?: { year?: number; month?: number; day?: number };
  endDate?: { year?: number; month?: number; day?: number };
  nextAiringEpisode?: {
    airingAt: number;
    episode: number;
    timeUntilAiring: number;
  };
  relations?: {
    edges?: {
      relationType: string;
      node: MediaItem;
    }[];
  };
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
  trailer?: {
    id: string;
    site: string;
    thumbnail?: string;
  };
  // User list fields
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
}

export interface Episode {
  number: number;
  title?: string;
  image?: string;
  description?: string;
  filler?: boolean;
}

export interface StreamServer {
  name: string;
  url: string;
  quality?: string;
  isM3U8?: boolean;
  headers?: Record<string, string>;
}

export interface Character {
  id: number;
  name: string;
  image?: string;
  role: string;
  voiceActors?: {
    id: number;
    name: string;
    image?: string;
    language: string;
  }[];
}

export interface Review {
  id: number;
  summary: string;
  body?: string;
  score: number;
  rating?: number;
  user: {
    id: number;
    name: string;
    avatar?: string;
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
  context?: string;
  media?: MediaItem;
  createdAt: number;
}

export interface UserProfile {
  id: number;
  name: string;
  avatar?: { large?: string };
  bannerImage?: string;
  about?: string;
  statistics?: {
    anime?: {
      count: number;
      meanScore: number;
      minutesWatched: number;
      episodesWatched: number;
    };
    manga?: {
      count: number;
      meanScore: number;
      chaptersRead: number;
      volumesRead: number;
    };
  };
}

export interface ListEntry {
  media: MediaItem;
  status: string;
  score: number;
  progress: number;
}
