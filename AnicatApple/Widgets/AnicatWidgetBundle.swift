import SwiftUI
import WidgetKit

@main
struct AnicatWidgetBundle: WidgetBundle {
    var body: some Widget {
        UpNextWidget()
        AiringTodayWidget()
        ContinueReadingWidget()
        DownloadLiveActivity()
        RemoteLiveActivity()
    }
}

/// The app's Ink & Index palette, by hand: the extension cannot import
/// `SumiTheme` without importing the whole UI target.
enum WidgetTheme {
    static let indigo = Color(red: 0.184, green: 0.353, blue: 0.463)
    static let indigoDark = Color(red: 0.561, green: 0.722, blue: 0.863)
    static let muted = Color.secondary

    static var accent: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.561, green: 0.722, blue: 0.863, alpha: 1)
                : UIColor(red: 0.184, green: 0.353, blue: 0.463, alpha: 1)
        })
    }
}

/// A cover fetched in the timeline provider. Widgets cannot use
/// `AsyncImage`; the bytes have to be in the entry.
struct CoverImage: View {
    let data: Data?
    var body: some View {
        if let data, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(.quaternary)
        }
    }
}

enum CoverFetcher {
    static func fetch(_ urlString: String?) async -> Data? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        // Small: a widget entry has a memory budget and a 2:3 poster at
        // 200px is plenty for a 60pt slot.
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        guard let image = UIImage(data: data) else { return data }
        let target = CGSize(width: 200, height: 300)
        let renderer = UIGraphicsImageRenderer(size: target)
        let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return scaled.jpegData(compressionQuality: 0.8)
    }
}
