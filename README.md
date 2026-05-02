# Anicat

A minimalist, high-performance **Anime & Manga CLI** for macOS.

Anicat is a terminal-native powerhouse designed for a distraction-free experience. Optimized for macOS and the Kitty terminal, it delivers lightning-fast streaming and manga reading with deep integration into the native environment.

## Key Features

*   **mpv Native Support**: High-performance playback with optimized header handling for protected streams and seamless auto-next logic.
*   **Premium Navigation**: Interactive menus featuring infinite wrap-around scrolling and intuitive `Right-Arrow` / `Enter` selection.
*   **High-Speed Manga Prefetching**: Proactive 15-page background buffer with intelligent resizing for instantaneous page turns.
*   **Kitty Terminal Integration**: Crisp, high-fidelity image previews using the `icat` protocol.
*   **AniList Integration**: Synchronize your watch history and discover new content directly through the CLI.
*   **Fuzzy-Search TUI**: Effortlessly browse your entire library with integrated `fzf` support.

## Installation

Anicat is best installed using [**uv**](https://github.com/astral-sh/uv):

```bash
uv tool install git+https://github.com/bonkedbythonk/anicat.git
```

### Prerequisites

To unlock the full potential of Anicat, the following tools are required/recommended:

*   [**mpv**](https://mpv.io/): The primary and required media player.
*   [**Kitty Terminal**](https://sw.kovidgoyal.net/kitty/): For high-performance image previews.
*   [**fzf**](https://github.com/junegunn/fzf): For the interactive selection menu.

## Linking AniList

To synchronize your progress with AniList, simply run the following command:

1.  **Start Authorization**:
    ```bash
    anicat anilist auth
    ```
    This will automatically open your browser to the AniList authorization page.
2.  **Get Your Token**: Authorize the application and copy the provided access token.
3.  **Save the Token**:

### Recommendation: Environment Variable (Persistent)
Add this to your `.zshrc` or `.bashrc` for the most reliable connection:
```bash
export ANILIST_TOKEN="YOUR_PERSONAL_ACCESS_TOKEN"
```

### Alternative: Quick Save
You can also save the token directly to Anicat's internal registry:
```bash
anicat anilist auth "YOUR_PERSONAL_ACCESS_TOKEN"
```

## Shortcuts (Manga Viewer)

*   `l` / `Right Arrow`: Next Page
*   `h` / `Left Arrow`: Previous Page
*   `s`: Toggle Spread Mode (Double Page View)
*   `b`: Toggle Information Banner
*   `q`: Exit Viewer

## Configuration

Anicat maintains a minimalist `config.toml` for easy customization.
**Path:** `~/Library/Application Support/anicat/config.toml`

## Credits

Anicat is a streamlined, macOS-specific fork of the [**Viu**](https://github.com/viu-media/viu) project.

This tool would not be possible without the incredible foundation laid by the original Viu development team. While Anicat has been refactored to specialize in the macOS ecosystem and Anime/Manga content, we remain deeply grateful to the original creators for their vision and architecture.
