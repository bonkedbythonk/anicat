import SwiftUI
import Foundation
import CryptoKit

/// One speech bubble found on a page. `rect` is in fractions of the page
/// (0...1), not pixels: mokuro measures the source image and the reader draws
/// a decode fitted to the window, so only proportions line up between them.
struct StudyBubble: Identifiable, Hashable {
    let id: String
    let page: Int
    let rect: CGRect
    let text: String
}

/// Reads mokuro's `.mokuro` volume file.
enum MokuroResult {
    private struct Volume: Decodable { let pages: [Page] }
    private struct Page: Decodable {
        let imgPath: String
        let imgWidth: Double
        let imgHeight: Double
        let blocks: [Block]
    }
    private struct Block: Decodable {
        let box: [Double]
        let lines: [String]
    }

    /// Bubbles keyed by page index. The index comes from the file name the
    /// runner gave each page (`007.jpg`), because mokuro lists pages in its
    /// own natural-sort order, which is not guaranteed to be reading order.
    static func bubbles(from data: Data) throws -> [Int: [StudyBubble]] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let volume = try decoder.decode(Volume.self, from: data)
        var result: [Int: [StudyBubble]] = [:]
        for page in volume.pages {
            let name = (page.imgPath as NSString).lastPathComponent
            guard let index = Int((name as NSString).deletingPathExtension),
                  page.imgWidth > 0, page.imgHeight > 0 else { continue }
            result[index] = page.blocks.enumerated().compactMap { offset, block in
                guard block.box.count == 4 else { return nil }
                let text = clean(block.lines)
                guard !text.isEmpty else { return nil }
                let (x0, y0, x1, y1) = (block.box[0], block.box[1], block.box[2], block.box[3])
                return StudyBubble(
                    id: "\(index)-\(offset)",
                    page: index,
                    rect: CGRect(
                        x: x0 / page.imgWidth,
                        y: y0 / page.imgHeight,
                        width: (x1 - x0) / page.imgWidth,
                        height: (y1 - y0) / page.imgHeight
                    ),
                    text: text
                )
            }
        }
        return result
    }

    /// manga-ocr writes an ellipsis as full-width full stops (`．．．`, and
    /// `．．` where the dots ran short): every trailing-off line in chapter 1
    /// of Fly Me to the Moon came out that way. A dictionary lookup on that
    /// text would treat the dots as characters, so they go back to `…` here.
    static func clean(_ lines: [String]) -> String {
        lines.joined()
            .replacingOccurrences(of: "．．．", with: "…")
            .replacingOccurrences(of: "．．", with: "…")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Study mode for one open chapter: runs the OCR once, then holds the bubbles
/// and the one the reader clicked.
@MainActor
@Observable
final class StudySession {
    enum State: Equatable {
        case off
        case reading
        case ready
        case failed(String)
    }

    private(set) var state: State = .off
    private(set) var bubbles: [Int: [StudyBubble]] = [:]
    var selected: StudyBubble?
    private var task: Task<Void, Never>?

    var isOn: Bool { state != .off }

    func toggle(pageURLs: [URL]) {
        if isOn { stop() } else { start(pageURLs) }
    }

    /// The reader keeps one view across chapter turns, so without this the
    /// last chapter's bubbles were drawn over the new chapter's pages.
    func chapterChanged(to pageURLs: [URL]) {
        guard isOn else { return }
        stop()
        start(pageURLs)
    }

    func stop() {
        task?.cancel()
        task = nil
        state = .off
        bubbles = [:]
        selected = nil
    }

    private func start(_ pageURLs: [URL]) {
        state = .reading
        task = Task {
            do {
                let data = try await Self.ocr(pageURLs)
                let found = try MokuroResult.bubbles(from: data)
                guard !Task.isCancelled else { return }
                bubbles = found
                state = .ready
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                AppLog.write("[study] OCR failed: \(error)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The `.mokuro` file for these pages, from the cache or a fresh run.
    /// Keyed on the page URLs, which the site serves unchanged between
    /// visits, so a chapter is read once and opens instantly after that.
    nonisolated private static func ocr(_ pageURLs: [URL]) async throws -> Data {
        #if os(macOS)
        let key = SHA256.hash(data: Data(pageURLs.map(\.absoluteString).joined(separator: "\n").utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let fm = FileManager.default
        let root = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Anicat/study", isDirectory: true)
        let result = root.appendingPathComponent("\(key).mokuro")
        if let cached = try? Data(contentsOf: result) { return cached }

        guard let uv = uvExecutable() else {
            throw Failure(message: "Study mode reads pages with mokuro, which runs through uv. Install uv with: brew install uv")
        }
        let pages = root.appendingPathComponent(key, isDirectory: true)
        try? fm.removeItem(at: pages)
        try fm.createDirectory(at: pages, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: pages)
            try? fm.removeItem(at: root.appendingPathComponent("_ocr/\(key)"))
            try? fm.removeItem(at: root.appendingPathComponent("\(key).html"))
        }
        for (index, url) in pageURLs.enumerated() {
            try Task.checkCancellation()
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let target = pages.appendingPathComponent(String(format: "%03d.%@", index, ext))
            if url.isFileURL {
                try fm.copyItem(at: url, to: target)
            } else {
                let (data, _) = try await URLSession.shared.data(from: url)
                try data.write(to: target)
            }
        }

        let log = root.appendingPathComponent("\(key).log")
        fm.createFile(atPath: log.path, contents: nil)
        let process = Process()
        process.executableURL = uv
        process.arguments = ["tool", "run", "--python", "3.11", "--from", "mokuro", "mokuro", pages.path, "--disable_confirmation"]
        process.currentDirectoryURL = root
        // A file, not a pipe: mokuro redraws a progress bar on stderr per
        // page, and an unread pipe fills and stalls the process mid-chapter.
        process.standardOutput = try FileHandle(forWritingTo: log)
        process.standardError = try FileHandle(forWritingTo: log)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
        guard status == 0, let data = try? Data(contentsOf: result) else {
            let tail = (try? String(contentsOf: log, encoding: .utf8))?
                .split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw Failure(message: "mokuro stopped (exit \(status)). \(tail)")
        }
        return data
        #else
        throw Failure(message: "Study mode needs the Mac app.")
        #endif
    }

    #if os(macOS)
    /// A Dock-launched app gets launchd's PATH, not the shell's, so uv is
    /// looked for where Homebrew and uv's own installer put it.
    nonisolated private static func uvExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(home)/.local/bin/uv", "\(home)/.cargo/bin/uv"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
    #endif
}

/// The clickable outlines over one decoded page.
struct StudyBubbleOverlay: View {
    let bubbles: [StudyBubble]
    let selectedID: String?
    let onSelect: (StudyBubble) -> Void

    var body: some View {
        GeometryReader { geo in
            ForEach(bubbles) { bubble in
                let isSelected = bubble.id == selectedID
                // mokuro's box hugs the glyphs; a few points of slack make the
                // outline read as the bubble rather than as a text cursor.
                let frame = CGRect(
                    x: bubble.rect.minX * geo.size.width,
                    y: bubble.rect.minY * geo.size.height,
                    width: bubble.rect.width * geo.size.width,
                    height: bubble.rect.height * geo.size.height
                ).insetBy(dx: -4, dy: -4)
                RoundedRectangle(cornerRadius: 6)
                    .fill(SumiTheme.indigo.opacity(isSelected ? 0.18 : 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(SumiTheme.indigo.opacity(isSelected ? 1 : 0.55), lineWidth: isSelected ? 2.5 : 1.5)
                    )
                    .frame(width: frame.width, height: frame.height)
                    // Before `.position`, which fills the whole page: after
                    // it every bubble's hit area was the page, the last one
                    // drawn took every click, and clicking any bubble showed
                    // the text of the bottom one.
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(bubble) }
                    .position(x: frame.midX, y: frame.midY)
            }
        }
    }
}

/// The text of the clicked bubble, or why study mode could not read the
/// chapter. Selectable so a line can be copied into a dictionary until the
/// reader has its own lookup.
struct StudyTextPanel: View {
    let bubble: StudyBubble?
    let failure: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(bubble.map { "Page \($0.page + 1)" } ?? "Study mode")
                    .sumiTabularMono(size: 11)
                    .foregroundColor(SumiTheme.muted)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(SumiTheme.foreground.opacity(0.8))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
            }
            if let bubble {
                Text(bubble.text)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(SumiTheme.foreground)
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let failure {
                Text(failure)
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.foreground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(SumiTheme.spaceMd)
        .frame(width: 320, alignment: .leading)
        .background(SumiTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusLg)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
    }
}
