import Foundation

/// Represents the Anime4K real-time neural upscaling state.
/// Tauri AniCat uses a single toggle (On / Off) backed by the official 6-shader chain.
public enum Anime4KPreset: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case on = "On"

    /// Backward compatibility alias for the default Anime4K Mode A (Fast) preset
    public static let modeAFast: Anime4KPreset = .on

    public var id: String { rawValue }
    public var displayName: String { rawValue }

    /// Official 6-shader chain from Tauri AniCat (Mode A - Fast)
    /// Source: github.com/bloc97/Anime4K
    public static let shaderFileNames: [String] = [
        "Anime4K_Clamp_Highlights.glsl",
        "Anime4K_Restore_CNN_M.glsl",
        "Anime4K_Upscale_CNN_x2_M.glsl",
        "Anime4K_AutoDownscalePre_x2.glsl",
        "Anime4K_AutoDownscalePre_x4.glsl",
        "Anime4K_Upscale_CNN_x2_S.glsl"
    ]

    /// Returns the ordered list of GLSL shader file names for this state.
    public var shaderFileNames: [String] {
        switch self {
        case .off:
            return []
        case .on:
            return Self.shaderFileNames
        }
    }

    /// Resolves the shader files into absolute path string format expected by mpv (`path1:path2:...`)
    public func resolveMpvShaderString(bundle: Bundle? = nil) -> String {
        guard self != .off else { return "" }
        let activeBundle = bundle ?? Self.resolveDefaultBundle()
        let paths = shaderFileNames.compactMap { name -> String? in
            let baseName = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            return activeBundle.path(forResource: baseName, ofType: ext, inDirectory: "Shaders")
                ?? activeBundle.path(forResource: baseName, ofType: ext, inDirectory: "Resources/Shaders")
                ?? activeBundle.path(forResource: name, ofType: nil)
                ?? Bundle.main.path(forResource: baseName, ofType: ext, inDirectory: "AnicatApple_AnicatUI.bundle/Shaders")
                ?? Bundle.main.path(forResource: baseName, ofType: ext, inDirectory: "Shaders")
        }

        #if os(Windows)
        return paths.joined(separator: ";")
        #else
        return paths.joined(separator: ":")
        #endif
    }

    /// `Bundle.module`'s generated accessor only ever checks `Bundle.main`'s
    /// bundle root (correct for a bare `swift run` executable, where that
    /// root *is* the directory next to the binary) or the `.build` tree — it
    /// has no case for a real signed `AniCat.app`, and would fatalError
    /// there before any of this function's own fallbacks ran. A signed app
    /// bundle can only hold the resource bundle under `Contents/Resources`
    /// (codesign refuses anything else sitting loose at the bundle root:
    /// "unsealed contents present in the bundle root"), so check that first
    /// and only fall through to `Bundle.module` — for `swift run` / tests —
    /// once it's confirmed not to be the crashing case.
    private static func resolveDefaultBundle() -> Bundle {
        let resourcesPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/AnicatApple_AnicatUI.bundle")
            .path
        if let bundle = Bundle(path: resourcesPath) {
            return bundle
        }
        return Bundle.module
    }
}

