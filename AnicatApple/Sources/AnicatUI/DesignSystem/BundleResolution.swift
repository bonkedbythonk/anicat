import Foundation

extension Foundation.Bundle {
    /// `Bundle.module`'s generated accessor only ever checks `Bundle.main`'s
    /// bundle root (correct for a bare `swift run` executable, where that
    /// root *is* the directory next to the binary) or the `.build` tree — it
    /// has no case for a real signed `Anicat.app`, and fatalErrors there
    /// before any fallback runs. A signed app bundle can only hold the
    /// resource bundle under `Contents/Resources` (codesign refuses anything
    /// loose at the bundle root: "unsealed contents present in the bundle
    /// root"), so check that first and only fall through to `Bundle.module`
    /// — for `swift run` / tests — once it's confirmed not to be the
    /// crashing case.
    ///
    /// Every lookup of AnicatUI's bundled images, fonts and shaders must go
    /// through this instead of `Bundle.module` directly: a raw `Bundle.module`
    /// reference crashes the whole app at launch the moment its static
    /// initializer runs inside a packaged `Anicat.app`, however far from the
    /// call site that happens to be.
    static var anicatResources: Bundle {
        let resourcesPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/AnicatApple_AnicatUI.bundle")
            .path
        if let bundle = Bundle(path: resourcesPath) {
            return bundle
        }
        return Bundle.module
    }
}
