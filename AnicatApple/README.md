# AnicatApple

The Apple half of the native refactor: a Swift package wrapping the Rust engine
in `../core`.

## Building

`AnicatCore.xcframework` and `Sources/AnicatCoreKit/anicat_core.swift` are build
artifacts and are not committed. Produce them before the first `swift build`:

```bash
bash scripts/build-xcframework.sh
```

That compiles `core/` for `aarch64-apple-darwin`, `aarch64-apple-ios` and
`aarch64-apple-ios-sim`, generates the Swift bindings **from the compiled
library** rather than from a `.udl` (the interface is declared with
`#[uniffi::export]` proc-macros, so the built artifact is the only complete
description of it), and packages the three static libraries.

Re-run it after any change to `core/src/ffi.rs`. Stale bindings link fine and
then call the wrong FFI symbols at runtime.

## Testing

```bash
cd AnicatApple && swift test
```

`testAsyncAnilistSearchCrossesTheBridge` hits the live AniList API; it skips
rather than fails when the network is unavailable.
