# AnicatApple

The Mac app: a Swift package over the Rust engine in `../core`.

## Build

The engine and its Swift bindings are build artifacts, not committed. Make
them once after cloning, and again after any change to `core/src/ffi.rs`
(stale bindings link fine and then call the wrong symbols at runtime):

```bash
bash scripts/build-xcframework.sh
cd AnicatApple && swift build --product Anicat
```

## Test

```bash
cd AnicatApple && swift test
```

A few suites hit the live AniList API and fail during its outages.
