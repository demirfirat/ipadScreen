import Foundation
import Network

/// Connects to the iPad over USB and sends the raw stream.
///
/// Over Wi-Fi the iPad connects to us; over USB the direction is reversed
/// because a `usbmuxd` tunnel can only be opened Mac → device. `iproxy`
/// opens a local port on the Mac and forwards it to the port the iPad is
/// listening on, and we connect to that local port. The wire format is
/// identical to Wi-Fi.
final class USBSender: FrameSink {

    let id: Int
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ipadscreen.usb")

    private var isOpen = false
    private var sentHeader = false
    private var confirmed = false
    private var hasClosed = false
    private var inFlight = 0
    private let lock = NSLock()
    private var reader = ControlLineReader()

    private let width: Int
    private let height: Int
    private let mode: LinkMode

    var onClose: ((Int) -> Void)?
    var onConnect: (() -> Void)?
    /// The iPad introduced itself: its device ID, and whether it's asking
    /// for a device key (it has none yet).
    var onHello: ((String?, Bool) -> Void)?

    private var heard = Date()

    /// When we last heard from the iPad; the heartbeat drops quiet clients.
    var lastHeard: Date {
        lock.lock(); defer { lock.unlock() }
        return heard
    }
    /// A control message from the iPad (e.g. "mode=wifi").
    var onControl: ((String) -> Void)?

    init(id: Int, localPort: UInt16, width: Int, height: Int, mode: LinkMode) {
        self.id = id
        self.width = width
        self.height = height
        self.mode = mode

        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: localPort)!,
            using: params)
    }

    func start() {
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                sendHeader()
                receive()
            case .failed(let error):
                Log.debug("USB connection error: \(error)")
                close()
            case .cancelled:
                // The echo of our own cancel; if `close()` already ran, the
                // flag stops it from running twice.
                close()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func sendHeader() {
        var hello = RawProtocol.header(width: width, height: height)
        hello.append(RawProtocol.controlPacket(RawProtocol.modeMessage(mode)))

        connection.send(content: hello, completion: .contentProcessed { [self] error in
            if error != nil {
                close()
                return
            }
            lock.lock()
            isOpen = true
            sentHeader = true
            lock.unlock()
        })
    }

    /// Reads messages from the iPad.
    ///
    /// The connection only counts as up once the iPad has said something.
    /// `iproxy` accepts our connection even when nothing is listening on the
    /// iPad and closes it a moment later, so "we connected" alone used to
    /// report USB as connected when it wasn't.
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                lock.lock()
                heard = Date()
                lock.unlock()
                for line in reader.feed(data) {
                    lock.lock()
                    let first = !confirmed
                    confirmed = true
                    lock.unlock()
                    if first { onConnect?() }
                    handle(line)
                }
            }
            if isComplete || error != nil {
                close()
                return
            }
            receive()
        }
    }

    /// "hello id=<device id> [pair]" introduces the iPad; "ping" is only
    /// there to keep the connection alive; anything else is a control
    /// message such as "mode=wifi".
    private func handle(_ line: String) {
        if line == "ping" { return }
        if line.hasPrefix("hello") {
            let words = line.split(separator: " ")
            let id = words.first { $0.hasPrefix("id=") }.map { String($0.dropFirst(3)) }
            let valid = id.map { PairingCrypto.isHex($0, length: 32) } ?? false
            onHello?(valid ? id : nil, words.contains("pair"))
            return
        }
        onControl?(line)
    }

    func send(_ frame: EncodedFrame) {
        lock.lock()
        // Keep the queue shallow. USB has bandwidth to spare, but the
        // bottleneck is the iPad's decode speed: a deep queue piles up
        // frames the device can't keep up with, turning them into latency
        // and a spike in dropped frames. Three frames keeps the decoder fed
        // while bounding latency.
        guard isOpen, sentHeader, confirmed, inFlight < 3 else {
            lock.unlock()
            return
        }
        inFlight += 1
        lock.unlock()

        connection.send(content: RawProtocol.framePacket(frame.data),
                        completion: .contentProcessed { [self] error in
            lock.lock()
            inFlight -= 1
            lock.unlock()
            if error != nil { close() }
        })
    }

    func sendControl(_ message: String) {
        lock.lock()
        let ready = isOpen && sentHeader
        lock.unlock()
        guard ready else { return }
        connection.send(content: RawProtocol.controlPacket(message),
                        completion: .contentProcessed { _ in })
    }

    var pendingWrites: Int {
        lock.lock(); defer { lock.unlock() }
        return inFlight
    }

    /// Closes exactly once. A one-shot flag is used because checking the
    /// connection state took the wrong branch on a notification that
    /// arrived during setup and closed the connection before it opened.
    func close() {
        lock.lock()
        guard !hasClosed else {
            lock.unlock()
            return
        }
        hasClosed = true
        isOpen = false
        lock.unlock()

        connection.cancel()
        onClose?(id)
    }
}
