import Foundation

/// Pictures a skin may show. A file in
/// `~/Library/Application Support/Anicat/skin-art/<skin>/<name>.jpg` wins, so
/// the owner can swap any picture without a rebuild; with none there, the copy
/// bundled under `Resources/SkinArt` answers. A name with neither answers nil
/// and the view draws nothing in its place, which is also how every skin
/// without art behaves.
///
/// The bundled pictures are wallhaven.cc game and fan art, committed at the
/// owner's say-so on 2026-10-17; they are not the app's own work.
public enum SkinArt {
    static let extensions = ["jpg", "jpeg", "png", "heic"]

    /// `root` is a parameter only so a test can point it at a temp folder.
    public static func url(
        _ name: String,
        skin: SumiSkin,
        root: URL? = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Anicat/skin-art", isDirectory: true)
    ) -> URL? {
        if let folder = root?.appendingPathComponent(skin.rawValue, isDirectory: true) {
            for ext in extensions {
                let candidate = folder.appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return bundled(name, skin: skin)
    }

    /// The copy that ships in the app, if the skin has one.
    static func bundled(_ name: String, skin: SumiSkin) -> URL? {
        for ext in extensions {
            if let url = Bundle.anicatResources.url(
                forResource: name, withExtension: ext, subdirectory: "SkinArt/\(skin.rawValue)"
            ) { return url }
        }
        return nil
    }
}
