import Foundation

public enum Anime4KPreset: String, CaseIterable, Identifiable, Sendable {
    case off = "Off"
    case modeAFast = "Mode A (Fast)"
    case modeAHQ = "Mode A (HQ)"
    case modeBFast = "Mode B (Fast)"
    case modeCFast = "Mode C (Fast)"

    public var id: String { rawValue }
    public var displayName: String { rawValue }

    /// Returns the ordered list of GLSL shader file names for this preset.
    public var shaderFileNames: [String] {
        switch self {
        case .off:
            return []
        case .modeAFast:
            // Anime4K Mode A (Fast) - Tuned for MacBook thermals and Apple Silicon efficiency
            return [
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Restore_CNN_M.glsl",
                "Anime4K_Upscale_CNN_x2_M.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Upscale_CNN_x2_S.glsl"
            ]
        case .modeAHQ:
            return [
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Restore_CNN_VL.glsl",
                "Anime4K_Upscale_CNN_x2_VL.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Upscale_CNN_x2_M.glsl"
            ]
        case .modeBFast:
            return [
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Restore_CNN_Soft_M.glsl",
                "Anime4K_Upscale_CNN_x2_M.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Upscale_CNN_x2_S.glsl"
            ]
        case .modeCFast:
            return [
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Upscale_Denoise_CNN_x2_M.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Upscale_CNN_x2_S.glsl"
            ]
        }
    }

    /// Resolves the shader files into absolute path string format expected by mpv (`path1:path2:...`)
    public func resolveMpvShaderString(bundle: Bundle? = nil) -> String {
        let activeBundle = bundle ?? Bundle.module
        let paths = shaderFileNames.compactMap { name -> String? in
            let baseName = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            return activeBundle.path(forResource: baseName, ofType: ext, inDirectory: "Resources/Shaders")
                ?? activeBundle.path(forResource: name, ofType: nil)
        }
        
        #if os(Windows)
        return paths.joined(separator: ";")
        #else
        return paths.joined(separator: ":")
        #endif
    }
}
