# Contributing to Anicat

Thanks for wanting to help. Anicat is maintained by one person, so the most
useful contributions are clear bug reports and small, focused pull requests.

## Reporting a bug

Open an issue with the **Bug report** template. The things that make a report
fixable:

- **The app version** (Anicat > About Anicat), and whether it is the Mac,
  iPhone or Windows build, with its OS version.
- **Which mode** you were in: Anime, Manga, Light novels, or Films and TV.
- **The log.** Settings > Advanced > Reveal Log File opens
  `~/Library/Logs/Anicat/anicat.log`. Attach the part around the problem;
  the previous three launches are kept as `anicat.log.1` to `.3`.
- **Nothing loads at all?** AniList has periodic outages during which it
  refuses requests from signed-out users. Check
  [AniList's status](https://anilist.co) before reporting.

Reports from the nightly build (install line in the README, under "Other
ways to install") are especially
welcome: they are how bugs get caught before a version reaches everyone. A
nightly's version ends in `-nightly.` and a timestamp; put the whole thing in
the report.

Security problems do not go in public issues; use GitHub's
[private advisory form](https://github.com/bonkedbythonk/anicat/security/advisories/new).

## Suggesting a feature

Open an issue with the **Feature request** template and describe the problem
you want solved, not only the solution. Requests to add a specific piracy site
or to share where content can be found will be closed.

## Development setup

The app is a Swift package (`AnicatApple/`, SwiftUI with libmpv in-process)
over a Rust engine (`core/`), joined by UniFFI. `ARCHITECTURE.md` has the full
picture.

You need macOS 15 on Apple silicon with Xcode's command line tools (Swift 6),
and [Rust](https://rustup.rs/) stable with the Apple targets:

```bash
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-tvos aarch64-apple-tvos-sim
```

No mpv install: libmpv and FFmpeg come from a fork of
[MPVKit](https://github.com/mpvkit/MPVKit) as SwiftPM binaries (about 1.7 GB
on first resolve).

```bash
bash scripts/build-xcframework.sh   # after cloning, and after any change to core/src/ffi.rs
cd AnicatApple && swift build --product Anicat
bash dev-run.sh                     # copies the binary into dist/Anicat.app and opens it
```

`scripts/package-anicat-macos-app.sh release` builds a standalone `.app` in
`AnicatApple/dist/`. The Windows build is the `server/` crate
(`cd server && cargo test`).

### iPhone and Apple TV

There is no `.xcodeproj` in the repo: it is generated from
`AnicatApple/project.yml` by [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). You need a full Xcode with the iOS or tvOS
platform, and `scripts/build-xcframework.sh` run first (above).

1. Give the apps bundle IDs of your own. `com.anicat.ios` and `com.anicat.tv`
   in `project.yml` belong to another developer account, and Xcode cannot
   sign an ID that is registered elsewhere. Change `PRODUCT_BUNDLE_IDENTIFIER`
   under `AnicatiOS` and `AnicatTV` to something like `com.yourname.anicat.tv`.
2. Export your Team ID (Xcode > Settings > Accounts) and the TMDB proxy, then
   generate. Both are read at generation time; without the proxy Films and TV
   is missing from the app.

   ```bash
   cd AnicatApple
   export ANICAT_DEVELOPMENT_TEAM=YOURTEAMID ANICAT_TMDB_PROXY=https://anicat-tmdb.anicat.workers.dev
   xcodegen generate
   ```
3. Open `Anicat.xcodeproj`, pick the `AnicatiOS` or `AnicatTV` scheme and your
   device, and run.

Regenerate after any change to `project.yml`, and never edit the generated
project. With a free Apple account the installed app stops opening after
seven days; build and run it again. Releases carry an unsigned iPhone `.ipa`
and no Apple TV build.

Stale bindings link fine and then call the wrong symbols at runtime, so rerun
`build-xcframework.sh` whenever `core/src/ffi.rs` or a type it exports changes.

## Before opening a pull request

Run the checks CI runs:

```bash
cd core && cargo test --lib && cargo clippy --lib --tests -- -D warnings
cd server && cargo test && cargo clippy --all-targets -- -D warnings
cd AnicatApple && swift build --product Anicat && swift test
python3 scripts/generate-third-party-notices.py --check
```

Four Swift suites query the live AniList API; they skip unless
`ANICAT_LIVE=1` is set, and fail during AniList outages when it is. If you
touched a shared view, also confirm it still compiles for the iOS and tvOS
Simulators, as CI does:

```bash
cd AnicatApple && swift build --product AnicatUI --triple arm64-apple-ios18.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --scratch-path .build-ios
cd AnicatApple && swift build --product AnicatUI --triple arm64-apple-tvos18.0-simulator --sdk "$(xcrun --sdk appletvsimulator --show-sdk-path)" --scratch-path .build-tvos
```

If your change touches `Cargo.lock`, regenerate the third-party notices with
`python3 scripts/generate-third-party-notices.py`; never edit the output by
hand.

## Style

- **English only**, in code, comments, UI strings and commit messages.
- **No emojis** anywhere.
- **Comments explain the failure, not the code.** A non-obvious constant,
  guard, or ordering carries a comment saying what broke without it, ideally
  with the measurement. A comment that restates the line is worse than none.
- **Commits follow [Conventional Commits](https://www.conventionalcommits.org)**
  with a scope, as in `fix(player): ...` or `feat(cinema): ...`. Squash
  "fix typo" and "try CI again" commits into the commit they belong to.
- Match the code around you: naming, structure, and how much is commented.

## License

Anicat is licensed under the [GNU General Public License v3.0](LICENSE). By
submitting a contribution you agree that it is licensed under the same terms.
