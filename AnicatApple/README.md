# AnicatApple

The Mac, iPhone and Apple TV apps: a Swift package over the Rust engine in
`../core`. The iPhone and TV targets live in `project.yml` (`xcodegen generate`).

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

Four suites hit the live AniList API. They skip unless `ANICAT_LIVE=1` is set,
and fail during AniList outages when it is.
