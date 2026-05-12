
import sys
import os
from pathlib import Path

# Add the project root to sys.path
sys.path.append(str(Path("/Users/thomas/Documents/randomcode/anicat").absolute()))

from anicat_media.cli.config.loader import ConfigLoader
from anicat_media.libs.provider.anime.provider import create_provider
from anicat_media.libs.provider.anime.params import SearchParams, AnimeParams, EpisodeStreamsParams
from httpx import Client

def test_download_flow():
    config = ConfigLoader().load()
    provider_name = config.general.provider
    print(f"Testing provider: {provider_name}")
    
    provider = create_provider(provider_name)
    
    query = "One Piece"
    print(f"Searching for: {query}")
    search_results = provider.search(SearchParams(query=query))
    
    if not search_results or not search_results.results:
        print("No search results found!")
        return

    result = search_results.results[0]
    print(f"Selected result: {result.title} (ID: {result.id})")
    
    print(f"Fetching details for ID: {result.id}")
    anime = provider.get(AnimeParams(id=result.id, query=query))
    
    if not anime:
        print("Failed to fetch anime details!")
        return
        
    print(f"Anime found: {anime.title}")
    
    translation_type = "sub"
    episodes = getattr(anime.episodes, translation_type)
    if not episodes:
        print(f"No {translation_type} episodes found!")
        return
        
    episode_number = episodes[0]
    print(f"Fetching streams for episode: {episode_number}")
    
    try:
        streams = provider.episode_streams(
            EpisodeStreamsParams(
                query=query,
                anime_id=anime.id,
                episode=episode_number,
                translation_type=translation_type
            )
        )
        
        if not streams:
            print("No streams found!")
            return
            
        streams_list = list(streams)
        if not streams_list:
            print("Streams iterator was empty!")
            return
            
        for i, stream in enumerate(streams_list):
            print(f"Server {i+1}: {stream.name}")
            for j, link in enumerate(stream.links):
                print(f"  Link {j+1}: {link.link[:50]}... (Quality: {link.quality})")
                
        print("\nDownload flow check successful up to stream link extraction.")
        
    except Exception as e:
        print(f"Error during stream extraction: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    test_download_flow()
