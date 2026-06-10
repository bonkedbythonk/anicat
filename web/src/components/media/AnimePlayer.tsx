import { usePlaybackStore, clearPlayback } from "@/stores/app";

export function AnimePlayer() {
  const { item, episode } = usePlaybackStore();
  if (!item || !episode) return null;
  return (
    <div className="absolute inset-0 bg-black z-50 flex flex-col">
      <div className="flex items-center justify-between p-4">
        <div>
          <h2 className="text-white font-medium">{item.title.romaji || item.title.english}</h2>
          <p className="text-gray-400 text-sm">Episode {episode.number}</p>
        </div>
        <button onClick={clearPlayback} className="text-white hover:text-gray-300 text-sm">Close</button>
      </div>
      <div className="flex-1 flex items-center justify-center">
        <p className="text-gray-400">Player controls loading...</p>
      </div>
    </div>
  );
}
