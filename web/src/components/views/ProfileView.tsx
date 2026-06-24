
import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Loader2, User, Clock, Tv, BookOpen, Bookmark, Heart } from "lucide-react";
import { mediaApi, type UserProfile, type MediaItem } from "@/lib/api";
import { proxyImage } from "@/lib/proxy";
import { useAppStore } from "@/stores/app";
import { LazyCard } from "@/components/media/LazyCard";

interface ProfileViewProps {
  onSelect?: (item: MediaItem) => void;
}

export function ProfileView({ onSelect }: ProfileViewProps) {
  const [favType, setFavType] = useState<"ANIME" | "MANGA">("ANIME");
  const isAuthenticated = useAppStore((s) => s.apiAuthenticated);

  const {
    data: profile,
    isLoading: loading,
  } = useQuery<UserProfile | null>({
    queryKey: ["profile"],
    queryFn: () => mediaApi.getProfile(),
    enabled: isAuthenticated,
  });

  if (loading) {
    return (
      <div className="flex items-center justify-center h-full">
        <Loader2 className="animate-spin text-accent" size={36} />
      </div>
    );
  }

  if (!profile) {
    return (
      <div className="flex flex-col items-center justify-center h-[50vh] space-y-4">
        <User size={48} className="text-gray-600" />
        <p className="text-gray-400 font-medium">Please connect AniList in {"Settings > AniList"} to view your profile.</p>
      </div>
    );
  }

  // Format watch minutes into Days and Hours
  function formatMinutes(mins?: number) {
    if (!mins) return "0 Days, 0 Hours";
    const days = Math.floor(mins / 1440);
    const hours = Math.floor((mins % 1440) / 60);
    return `${days} Days, ${hours} Hours`;
  }



  const favorites = favType === "ANIME" 
    ? profile.favorite_anime || [] 
    : profile.favorite_manga || [];

  return (
    <div className="animate-fade-in max-w-7xl space-y-8 pb-12">
      {/* 1. Header Banner & Profile Card */}
      <div className="relative rounded-3xl overflow-hidden bg-surface border border-white/[0.06] shadow-2xl">
        {profile.banner_url ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img src={proxyImage(profile.banner_url)} alt="Banner" className="w-full h-48 lg:h-72 object-cover brightness-[0.6]" />
        ) : (
          <div className="w-full h-48 lg:h-72 bg-gradient-to-r from-accent to-secondary opacity-30" />
        )}
        
        <div className="px-6 lg:px-8 pb-8 relative -mt-16 lg:-mt-20">
          <div className="flex flex-col md:flex-row md:items-end space-y-4 md:space-y-0 md:space-x-6">
            {profile.avatar_url ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={profile.avatar_url} alt="Avatar" className="w-32 h-32 lg:w-40 lg:h-40 rounded-2xl object-cover border-4 border-surface shadow-2xl" />
            ) : (
              <div className="w-32 h-32 lg:w-40 lg:h-40 rounded-2xl bg-white/10 border-4 border-surface flex items-center justify-center">
                <User size={48} className="text-white/50" />
              </div>
            )}
            
            <div className="pb-2">
              <h1 className="text-4xl lg:text-5xl font-extrabold text-white tracking-tight">{profile.name}</h1>
              <p className="text-accent font-semibold mt-1">AniList Connected</p>
            </div>
          </div>
        </div>
      </div>

      {/* 2. Main statistics dashboard cards */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-5">
        <div className="group relative rounded-2xl bg-surface border border-white/[0.04] p-6 hover:border-accent/40 hover:bg-white/[0.02] transition-all duration-300">
          <div className="flex items-start justify-between">
            <div className="space-y-2">
              <p className="text-xs font-semibold text-gray-500 tracking-wider uppercase">Watch Time</p>
              <h3 className="text-2xl font-black text-white group-hover:text-accent transition-colors">
                {formatMinutes(profile.minutes_watched)}
              </h3>
              <p className="text-xs text-gray-400">{profile.anime_count || 0} Anime tracked</p>
            </div>
            <div className="p-3 rounded-xl bg-violet-500/10 text-violet-400 group-hover:scale-110 transition-transform">
              <Clock size={20} />
            </div>
          </div>
        </div>

        <div className="group relative rounded-2xl bg-surface border border-white/[0.04] p-6 hover:border-pink-500/40 hover:bg-white/[0.02] transition-all duration-300">
          <div className="flex items-start justify-between">
            <div className="space-y-2">
              <p className="text-xs font-semibold text-gray-500 tracking-wider uppercase">Episodes Watched</p>
              <h3 className="text-2xl font-black text-white group-hover:text-pink-400 transition-colors">
                {profile.episodes_watched?.toLocaleString() || "0"}
              </h3>
              <p className="text-xs text-gray-400">Completed episodes</p>
            </div>
            <div className="p-3 rounded-xl bg-pink-500/10 text-pink-400 group-hover:scale-110 transition-transform">
              <Tv size={20} />
            </div>
          </div>
        </div>

        <div className="group relative rounded-2xl bg-surface border border-white/[0.04] p-6 hover:border-cyan-500/40 hover:bg-white/[0.02] transition-all duration-300">
          <div className="flex items-start justify-between">
            <div className="space-y-2">
              <p className="text-xs font-semibold text-gray-500 tracking-wider uppercase">Chapters Read</p>
              <h3 className="text-2xl font-black text-white group-hover:text-cyan-400 transition-colors">
                {profile.chapters_read?.toLocaleString() || "0"}
              </h3>
              <p className="text-xs text-gray-400">{profile.manga_count || 0} Manga tracked</p>
            </div>
            <div className="p-3 rounded-xl bg-cyan-500/10 text-cyan-400 group-hover:scale-110 transition-transform">
              <BookOpen size={20} />
            </div>
          </div>
        </div>

        <div className="group relative rounded-2xl bg-surface border border-white/[0.04] p-6 hover:border-amber-500/40 hover:bg-white/[0.02] transition-all duration-300">
          <div className="flex items-start justify-between">
            <div className="space-y-2">
              <p className="text-xs font-semibold text-gray-500 tracking-wider uppercase">Volumes Read</p>
              <h3 className="text-2xl font-black text-white group-hover:text-amber-400 transition-colors">
                {profile.volumes_read?.toLocaleString() || "0"}
              </h3>
              <p className="text-xs text-gray-400">Completed volumes</p>
            </div>
            <div className="p-3 rounded-xl bg-amber-500/10 text-amber-400 group-hover:scale-110 transition-transform">
              <Bookmark size={20} />
            </div>
          </div>
        </div>
      </div>



      {/* 4. Interactive Favorites Showcase Grid */}
      <div className="space-y-6">
        <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4 border-b border-white/[0.06] pb-4">
          <h2 className="text-2xl font-black text-white flex items-center space-x-2">
            <Heart size={22} className="text-accent fill-accent" />
            <span>Favorites Showcase</span>
          </h2>
          
          <div className="flex bg-white/[0.04] p-1 rounded-xl border border-white/[0.06] w-fit self-end sm:self-auto">
            <button
              onClick={() => setFavType("ANIME")}
              className={`flex items-center space-x-2 px-4 py-2 rounded-lg font-semibold text-sm transition-all ${
                favType === "ANIME" ? "bg-accent text-white shadow-lg shadow-accent/20" : "text-gray-500 hover:text-white"
              }`}
            >
              <Tv size={16} />
              <span>Anime</span>
            </button>
            <button
              onClick={() => setFavType("MANGA")}
              className={`flex items-center space-x-2 px-4 py-2 rounded-lg font-semibold text-sm transition-all ${
                favType === "MANGA" ? "bg-accent text-white shadow-lg shadow-accent/20" : "text-gray-500 hover:text-white"
              }`}
            >
              <BookOpen size={16} />
              <span>Manga</span>
            </button>
          </div>
        </div>

        {favorites.length > 0 ? (
          <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-5">
            {favorites.map((item) => (
              <LazyCard key={item.id} item={item} onSelect={onSelect ?? (() => {})} />
            ))}
          </div>
        ) : (
          <div className="text-center py-12 bg-white/[0.02] border border-white/[0.04] rounded-2xl">
            <Heart className="mx-auto text-gray-700 mb-2" size={32} />
            <p className="text-gray-500 font-semibold text-sm">No favorite {favType.toLowerCase()} added to showcase</p>
          </div>
        )}
      </div>
    </div>
  );
}
