import Foundation
import Network

/// Pumps one byte range from the Mac's loopback range server out to a phone
/// over a dedicated connection.
///
/// The engine's server stays bound to `127.0.0.1` -- it authenticates
/// nothing and hands out whatever file id it is asked for, which is exactly
/// why `torrent/stream.rs` refuses to leave loopback. This relay is what
/// lets a phone read it anyway: the bytes cross the network over a
/// connection that has already proved it belongs to a paired device, and the
/// file server itself is never exposed.
final class StreamRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let onFinish: @Sendable () -> Void
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var sentHeader = false

    init(connection: NWConnection, onFinish: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.onFinish = onFinish
        super.init()
        let config = URLSessionConfiguration.ephemeral
        // The range server can block for as long as the swarm takes to
        // deliver the piece the read landed on, which after a seek into a
        // cold part of the file is measured in tens of seconds. The default
        // 60s resource timeout would abort a legitimate wait.
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func start(url: URL, start: Int64, end: Int64) {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            connection.sendFrame(.dataError("range server answered \((response as? HTTPURLResponse)?.statusCode ?? -1)"))
            completionHandler(.cancel)
            finish()
            return
        }
        let length = http.expectedContentLength
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? "video/x-matroska"
        connection.sendFrame(.dataHeader(length: length, contentType: type))
        sentHeader = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Suspend before sending and resume when the socket has taken the
        // bytes. Without it, a Mac reading from a warm cache at disk speed
        // outruns the Wi-Fi and the whole rest of the file queues up inside
        // `NWConnection` -- gigabytes of it, on the machine that is also
        // running the torrent session.
        dataTask.suspend()
        connection.send(content: data, completion: .contentProcessed { [weak dataTask] error in
            guard error == nil else {
                dataTask?.cancel()
                return
            }
            dataTask?.resume()
        })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, !sentHeader {
            connection.sendFrame(.dataError(error.localizedDescription))
        }
        finish()
    }

    private func finish() {
        // The connection closing is what tells the phone the range ended:
        // the header carried the length, so a short read is a failure the
        // phone can see rather than a truncation it cannot.
        connection.cancel()
        session.finishTasksAndInvalidate()
        onFinish()
    }
}
