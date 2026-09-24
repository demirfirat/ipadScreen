import Foundation
import Network

/// Streams JPEG frames to a browser using `multipart/x-mixed-replace`.
///
/// Used instead of WebSocket: no handshake, no framing, no JavaScript on the
/// client. The browser renders the stream straight into an `<img>` tag and
/// each new part replaces the previous one. Every browser supports this
/// natively, iOS 6 Safari included.
final class MJPEGClient: FrameSink {

    /// Boundary string between parts. The payload is JPEG, so it can't
    /// collide with the data.
    static let boundary = "ipadscreenframe"

    private let connection: NWConnection
    let id: Int

    private var isOpen = true
    private let stateLock = NSLock()

    /// Frames currently being sent. Keeps a slow client from piling up frames.
    private var inFlight = 0

    var onClose: ((Int) -> Void)?

    init(connection: NWConnection, id: Int) {
        self.connection = connection
        self.id = id
    }

    /// Sends the stream headers and starts accepting frames.
    func start() {
        let header =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: multipart/x-mixed-replace; boundary=\(Self.boundary)\r\n" +
            "Cache-Control: no-cache, no-store, must-revalidate\r\n" +
            "Pragma: no-cache\r\n" +
            "Connection: close\r\n" +
            "\r\n"

        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { self.close() }
        })

        // Keep reading so we notice the client going away; this is how we
        // learn the browser tab was closed.
        watchForClose()
    }

    private func watchForClose() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.close()
                return
            }
            self.watchForClose()
        }
    }

    /// Appends a frame to the stream.
    ///
    /// If earlier frames are still in flight the new one is dropped: queueing
    /// a late frame makes the delay permanent, and what matters here is the
    /// current state of the screen.
    func send(_ frame: EncodedFrame) {
        stateLock.lock()
        // While one frame is sending we keep the next one ready. At 60 fps
        // frames arrive 16 ms apart, so a deeper queue turns directly into
        // latency: stale frames get shown instead of being skipped. Two
        // frames is ~33 ms, below what's noticeable.
        guard isOpen, inFlight < 2 else {
            stateLock.unlock()
            return
        }
        inFlight += 1
        stateLock.unlock()

        let partHeader =
            "--\(Self.boundary)\r\n" +
            "Content-Type: image/jpeg\r\n" +
            "Content-Length: \(frame.data.count)\r\n" +
            "\r\n"

        var packet = Data(partHeader.utf8)
        packet.append(frame.data)
        packet.append(Data("\r\n".utf8))

        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.stateLock.lock()
            self.inFlight -= 1
            self.stateLock.unlock()
            if error != nil { self.close() }
        })
    }

    /// For the quality controller: how far behind is this client?
    var pendingWrites: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return inFlight
    }

    func close() {
        stateLock.lock()
        guard isOpen else {
            stateLock.unlock()
            return
        }
        isOpen = false
        stateLock.unlock()

        connection.cancel()
        onClose?(id)
    }
}
