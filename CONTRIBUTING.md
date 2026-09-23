# Contributing to Anicat

Thanks for wanting to help. Anicat is maintained by one person, so the most
useful contributions are clear bug reports and small, focused pull requests.

## Reporting a bug

Open an issue with the **Bug report** template. The things that make a report
fixable:

- **The app version** (Anicat > About Anicat) and your macOS version.
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

No mpv install: libmpv and FFmpeg come from [MPVKit](https://github.com/mpvkit/MPVKit)
as SwiftPM binaries (about 1.7 GB on first resolve).

```bash
bash scripts/build-xcframework.sh   # after cloning, and after any change to core/src/ffi.rs
cd AnicatApple && swift build --product Anicat
bash dev-run.sh                     # copies the binary into dist/Anicat.app and opens it
```

`scripts/package-anicat-macos-app.sh release` builds a standalone `.app` in
`AnicatApple/dist/`. The iPhone and Apple TV apps are not released; build
them from Xcode after `cd AnicatApple && xcodegen generate` (needs a full
Xcode and [xcodegen](https://github.com/yonaskolb/XcodeGen)).

Stale bindings link fine and then call the wrong symbols at runtime, so rerun
`build-xcframework.sh` whenever `core/src/ffi.rs` or a type it exports changes.

## Before opening a pull request

Run the checks CI runs:

```bash
cd core && cargo test --lib && cargo clippy --lib --tests -- -D warnings
cd AnicatApple && swift build --product Anicat && swift test
```

Three Swift test suites query the live AniList API and fail during its
outages; that is not your change. If you touched a shared view, also confirm
it still compiles for the iOS Simulator:

```bash
cd AnicatApple && swift build --product AnicatUI --triple arm64-apple-ios18.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --scratch-path .build-ios
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
