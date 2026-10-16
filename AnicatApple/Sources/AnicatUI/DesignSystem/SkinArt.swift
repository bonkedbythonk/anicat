import Foundation

/// Pictures a skin may show, read from a folder on this Mac and never from the
/// bundle: `~/Library/Application Support/Anicat/skin-art/<skin>/<name>.jpg`.
///
/// The art a skin wants is somebody else's illustration, so it cannot ship in
/// the app or sit in the repo. A name with no file answers nil and the view
/// draws nothing in its place, which is also how every other skin behaves.
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
        guard let folder = root?.appendingPathComponent(skin.rawValue, isDirectory: true) else { return nil }
        for ext in extensions {
            let candidate = folder.appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
