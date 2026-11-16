import Foundation

/// Represents the Anime4K real-time neural upscaling state: a single toggle
/// (On / Off) backed by the official 6-shader chain, as the Tauri build had.
public enum Anime4KPreset: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case on = "On"

    public var id: String { rawValue }
    public var displayName: String { rawValue }

    /// Official 6-shader chain (Mode A - Fast), carried over from the Tauri build
    /// Source: github.com/bloc97/Anime4K
    public static let shaderFileNames: [String] = [
        "Anime4K_Clamp_Highlights.glsl",
        "Anime4K_Restore_CNN_M.glsl",
        "Anime4K_Upscale_CNN_x2_M.glsl",
        "Anime4K_AutoDownscalePre_x2.glsl",
        "Anime4K_AutoDownscalePre_x4.glsl",
        "Anime4K_Upscale_CNN_x2_S.glsl"
    ]

    /// The Apple TV's chain: the Mac's minus its two M-size stages, with
    /// the small Restore. Restore is where the visible gain is: upscalers
    /// alone (FSR, RAVU-lite, Anime4K x2_S) looked the same as mpv's
    /// lanczos at 1080p to 4K, and the Mac's six-shader chain is too much
    /// for a fanless A15. Picked by the owner from side-by-side renders;
    /// its frame rate on a real box is unmeasured.
    public static let tvShaderFileNames: [String] = [
        "Anime4K_Clamp_Highlights.glsl",
        "Anime4K_Restore_CNN_S.glsl",
        "Anime4K_Upscale_CNN_x2_S.glsl"
    ]

    /// Returns the ordered list of GLSL shader file names for this state.
    public var shaderFileNames: [String] {
        switch self {
        case .off:
            return []
        case .on:
            #if os(tvOS)
            return Self.tvShaderFileNames
            #else
            return Self.shaderFileNames
            #endif
        }
    }

    /// Resolves the shader files into absolute path string format expected by mpv (`path1:path2:...`)
    public func resolveMpvShaderString(bundle: Bundle? = nil) -> String {
        guard self != .off else { return "" }
        // Test hook: a chain of absolute paths replaces the bundled one, so
        // a candidate network can be A/B measured in the same harness as
        // the shipped chain without a rebuild per variant.
        if let override = DebugHooks.env("ANICAT_DEBUG_SHADERS"), !override.isEmpty {
            return override
        }
        let activeBundle = bundle ?? Bundle.anicatResources
        let paths = shaderFileNames.compactMap { name -> String? in
            let baseName = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            return activeBundle.path(forResource: baseName, ofType: ext, inDirectory: "Shaders")
                ?? activeBundle.path(forResource: baseName, ofType: ext, inDirectory: "Resources/Shaders")
                ?? activeBundle.path(forResource: name, ofType: nil)
                ?? Bundle.main.path(forResource: baseName, ofType: ext, inDirectory: "AnicatApple_AnicatUI.bundle/Shaders")
                ?? Bundle.main.path(forResource: baseName, ofType: ext, inDirectory: "Shaders")
        }

        return paths.joined(separator: ":")
    }
}

