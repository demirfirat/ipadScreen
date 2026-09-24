import Foundation
import Network

/// Anything that can receive frames. Shared by the browser (MJPEG) and the
/// native app (raw stream) so both fit in the same broadcast list.
protocol FrameSink: AnyObject {
    var id: Int { get }
    func send(_ frame: EncodedFrame)
    /// Sends a control message. Only the native app understands them; the
    /// browser stream ignores them.
    func sendControl(_ message: String)
    var pendingWrites: Int { get }
    func close()
}

extension FrameSink {
    func sendControl(_ message: String) {}
}

/// HTTP server for the viewer page and both stream types, plus the USB
/// sender.
///
/// Everything goes through one port, routed by request path: `/stream` is
/// MJPEG for browsers, `/raw` is the native app's stream, anything else is
/// the viewer page.
final class StreamServer {

    /// Bonjour service type. The iPad app browses for the same string.
    static let bonjourType = "_ipadscreen._tcp"

    private let port: NWEndpoint.Port
    private var listener: NWListener?

    /// Accepts connections and serves requests. Must be concurrent: on a
    /// serial queue, frames going out many times a second queued up ahead
    /// of page requests and the page never loaded.
    private let queue = DispatchQueue(label: "ipadscreen.server", attributes: .concurrent)

    private var clients: [Int: any FrameSink] = [:]
    private let clientsLock = NSLock()
    private var nextClientID = 1

    /// Called when the client count changes (for logging and the UI).
    var onClientCountChanged: ((Int) -> Void)?

    // MARK: - Link mode

    /// Current link mode, shared with the iPad app. See `LinkMode`.
    private(set) var mode: LinkMode

    /// The iPad asked to change the link mode. The engine decides and then
    /// calls `setMode`, which tells every native client.
    var onModeRequest: ((LinkMode) -> Void)?

    /// Changes the mode and tells every native client, so the iPad's
    /// selection follows the Mac's.
    func setMode(_ newMode: LinkMode) {
        clientsLock.lock()
        mode = newMode
        let all = Array(clients.values) + (usbSender.map { [$0] } ?? [])
        clientsLock.unlock()

        let message = RawProtocol.modeMessage(newMode)
        for client in all { client.sendControl(message) }
    }

    private func handleControl(_ message: String) {
        if let requested = RawProtocol.mode(from: message) {
            onModeRequest?(requested)
        }
    }

    // MARK: - USB

    /// The USB sender, from the moment it starts connecting. It only joins
    /// `clients` once the iPad has answered, so a half-open tunnel doesn't
    /// count as a connected device.
    private var usbSender: USBSender?
    private var usbEnabled = false
    private var usbPort: UInt16 = 0

    /// Starts connecting to the iPad over USB, and keeps retrying while
    /// enabled. The Wi-Fi listener stays up too, so the browser path and the
    /// Wi-Fi fallback keep working when the cable is pulled.
    func enableUSB(localPort: UInt16) {
        clientsLock.lock()
        usbEnabled = true
        usbPort = localPort
        clientsLock.unlock()
        connectUSB()
    }

    /// Stops using USB and closes the USB connection without retrying.
    func disableUSB() {
        clientsLock.lock()
        usbEnabled = false
        let sender = usbSender
        usbSender = nil
        if let sender { clients.removeValue(forKey: sender.id) }
        clientsLock.unlock()

        sender?.close()
        if usbActive {
            usbActive = false
            onClientCountChanged?(clientCount)
        }
    }

    private func connectUSB() {
        clientsLock.lock()
        guard usbEnabled, usbSender == nil else {
            clientsLock.unlock()
            return
        }
        let id = nextClientID
        nextClientID += 1
        let sender = USBSender(id: id, localPort: usbPort,
                               width: pageConfig.width, height: pageConfig.height,
                               mode: mode)
        usbSender = sender
        clientsLock.unlock()

        sender.onConnect = { [weak self] in
            guard let self else { return }

            // If the same iPad is connected over both Wi-Fi and USB we send
            // every frame twice, splitting bandwidth and the device's decode
            // capacity in half. Once USB is up, drop the native Wi-Fi
            // connections. Browser viewers stay; they may be other devices.
            // Connections still in their handshake count too: left alone,
            // they'd finish it a moment later and get every frame as well.
            self.clientsLock.lock()
            let wifi = self.clients.filter { $0.value is RawStreamClient }
            for (key, _) in wifi { self.clients.removeValue(forKey: key) }
            let pending = Array(self.pendingNative.values)
            self.pendingNative.removeAll()
            self.clients[id] = sender
            self.clientsLock.unlock()

            for (_, client) in wifi { client.close() }
            for client in pending { client.close() }
            self.usbActive = true
            Log.success("iPad connected over USB")
            self.onClientCountChanged?(self.clientCount)

            self.clientsLock.lock()
            let last = self.lastFrame
            self.clientsLock.unlock()
            if let last { sender.send(last) }
        }
        sender.onControl = { [weak self] message in
            self?.handleControl(message)
        }
        sender.onHello = { [weak self, weak sender] deviceID, wantsKey in
            // Pairing over the cable: an iPad without a key (or one the Mac
            // doesn't know) gets one here, no PIN needed. Afterwards it can
            // connect over Wi-Fi with that key.
            guard let self, let sender, let deviceID else { return }
            if wantsKey || self.deviceKey(for: deviceID) == nil {
                let key = self.issueDeviceKey(for: deviceID)
                sender.sendControl("key=" + key.map { String(format: "%02x", $0) }.joined())
                Log.success("iPad paired over USB")
            }
        }
        sender.onClose = { [weak self] closedID in
            guard let self else { return }
            self.clientsLock.lock()
            let wasConnected = self.clients.removeValue(forKey: closedID) != nil
            if self.usbSender === sender { self.usbSender = nil }
            let retry = self.usbEnabled
            self.clientsLock.unlock()

            if wasConnected {
                self.usbActive = false
                Log.info("USB connection closed")
                self.onClientCountChanged?(self.clientCount)
            }
            // While USB is wanted, keep trying: the cable may come back, or
            // the iPad app may not be open yet.
            if retry {
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    self.connectUSB()
                }
            }
        }

        sender.start()
    }

    private let webRoot: URL
    private var pageConfig: PageConfig

    struct PageConfig {
        var width: Int
        var height: Int
        var fps: Int
    }

    init(port: UInt16, webRoot: URL, config: PageConfig, mode: LinkMode, pairingCode: String) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.webRoot = webRoot
        self.pageConfig = config
        self.mode = mode
        self.pairingCode = pairingCode
    }

    func updateConfig(_ config: PageConfig) {
        pageConfig = config
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        // The iPad arrives over IPv4 on the LAN. By default NWListener opens
        // an IPv6-only socket; requests from the Mac itself go over IPv6
        // localhost and seem to work, but IPv4 packets from the network never
        // reach it. Pin the socket to IPv4 explicitly.
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }

        // Nagle off so small JPEGs don't sit for 40 ms before sending.
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        let listener = try NWListener(using: params, on: port)

        // Advertise over Bonjour so the iPad app finds this Mac by itself,
        // with no IP address to type in. The name defaults to the Mac's
        // computer name.
        listener.service = NWListener.Service(type: Self.bonjourType)

        listener.newConnectionHandler = { [self] conn in
            handle(conn)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Log.error("Server error: \(error)")
            }
        }
        listener.start(queue: queue)
        startHeartbeat()
        self.listener = listener
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        disableUSB()
        listener?.cancel()
        clientsLock.lock()
        let all = Array(clients.values)
        clients.removeAll()
        clientsLock.unlock()
        all.forEach { $0.close() }
    }

    /// Total bytes sent; the UI's bandwidth readout uses it.
    private(set) var bytesSent: UInt64 = 0

    /// Whether USB is actually connected. USB being selected isn't enough:
    /// if the tunnel doesn't come up the stream silently continues over
    /// Wi-Fi, and the UI used to report the wrong link.
    private(set) var usbActive = false

    /// The most recent frame. Capture only produces frames when the screen
    /// changes, so without this a viewer connecting to a static desktop
    /// would stay black until something moved.
    private var lastFrame: EncodedFrame?

    /// Sends a frame to every connected client.
    func broadcast(_ frame: EncodedFrame) {
        clientsLock.lock()
        lastFrame = frame
        let all = Array(clients.values)
        bytesSent &+= UInt64(frame.data.count * all.count)
        clientsLock.unlock()
        all.forEach { $0.send(frame) }
    }

    /// Largest number of pending writes across clients.
    var maxPendingWrites: Int {
        clientsLock.lock(); defer { clientsLock.unlock() }
        return clients.values.map(\.pendingWrites).max() ?? 0
    }

    var clientCount: Int {
        clientsLock.lock(); defer { clientsLock.unlock() }
        return clients.count
    }

    // MARK: - Pairing

    /// Code a device must present to get the stream over Wi-Fi. Without it,
    /// anyone on the same network could open the URL and watch the screen.
    /// USB doesn't need it: the cable already means physical access.
    private var pairingCode: String
    private let authLock = NSLock()

    var currentPairingCode: String {
        authLock.lock(); defer { authLock.unlock() }
        return pairingCode
    }

    /// Replaces the code and drops every Wi-Fi viewer paired with the old one.
    func setPairingCode(_ code: String) {
        authLock.lock()
        pairingCode = code
        failures.removeAll()
        authLock.unlock()

        clientsLock.lock()
        let wifi = clients.filter { !($0.value is USBSender) }
        for (key, _) in wifi { clients.removeValue(forKey: key) }
        let pending = Array(pendingNative.values)
        pendingNative.removeAll()
        clientsLock.unlock()
        for (_, client) in wifi { client.close() }
        for client in pending { client.close() }
        onClientCountChanged?(clientCount)
    }

    enum AuthResult: Equatable {
        case ok
        /// No code was sent. Not counted as a failed attempt, so a device
        /// that hasn't been given the code yet doesn't lock itself out.
        case missing
        case wrong
        /// Too many wrong codes from this address; refused for a while.
        case locked
    }

    /// Wrong attempts per remote address. Four digits is only 10,000
    /// possibilities; without a limit, anyone on the network could try them
    /// all in seconds. Five wrong tries lock the address out for a minute,
    /// which makes guessing take over a day on average.
    private var failures: [String: (count: Int, lockedUntil: Date?)] = [:]
    private let maxFailures = 5
    private let lockout: TimeInterval = 60

    /// Checks the code in a browser request's URL (`?code=1234`). The
    /// browser can't run the challenge-response handshake the native app
    /// uses, so this path is weaker: the code travels in the clear.
    private func authorize(_ conn: NWConnection, request: String) -> AuthResult {
        let address = Self.remoteAddress(conn)
        guard !isLocked(address) else { return .locked }
        guard let given = Self.queryValue("code", in: request), !given.isEmpty else { return .missing }
        if PairingCrypto.equal(given, currentPairingCode) {
            clearFailures(address)
            return .ok
        }
        recordFailure(address)
        return isLocked(address) ? .locked : .wrong
    }

    /// Checks the native app's answer to a PIN challenge.
    func checkPin(proof: String, clientNonce: String, serverNonce: String,
                  address: String) -> AuthResult {
        guard !isLocked(address) else { return .locked }
        let expected = PairingCrypto.proof(key: Data(currentPairingCode.utf8), tag: "P",
                                           clientNonce: clientNonce, serverNonce: serverNonce)
        if PairingCrypto.equal(proof, expected) {
            clearFailures(address)
            return .ok
        }
        recordFailure(address)
        return isLocked(address) ? .locked : .wrong
    }

    func isLocked(_ address: String) -> Bool {
        authLock.lock(); defer { authLock.unlock() }
        guard let until = failures[address]?.lockedUntil else { return false }
        if until > Date() { return true }
        failures[address] = nil
        return false
    }

    func recordFailure(_ address: String) {
        authLock.lock(); defer { authLock.unlock() }
        var entry = failures[address] ?? (0, nil)
        entry.count += 1
        if entry.count >= maxFailures {
            entry = (0, Date().addingTimeInterval(lockout))
            Log.info("Too many failed pairing attempts from \(address); blocked for \(Int(lockout)) s")
        }
        failures[address] = entry
    }

    private func clearFailures(_ address: String) {
        authLock.lock(); defer { authLock.unlock() }
        failures[address] = nil
    }

    /// Streams at most this many viewers at once. Each one gets every frame,
    /// so without a cap a flood of connections would bog the Mac down.
    private let maxClients = 4

    private var hasRoomForClient: Bool {
        clientsLock.lock(); defer { clientsLock.unlock() }
        return clients.count < maxClients
    }

    private func reject(_ conn: NWConnection, status: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    /// Code entry page for browsers. Plain HTML form, no JavaScript, so it
    /// works in iOS 6 Safari.
    private func codePage(_ auth: AuthResult) -> String {
        let note: String
        switch auth {
        case .wrong:  note = "<p class=\"err\">Wrong code, try again.</p>"
        case .locked: note = "<p class=\"err\">Too many wrong codes. Wait a minute and try again.</p>"
        default:      note = ""
        }
        return """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
            <title>iPadScreen</title>
            <style>
              body { background:#000; color:#ccc; font:17px -apple-system,Helvetica,sans-serif;
                     text-align:center; padding-top:120px; margin:0; }
              h1 { font-size:22px; font-weight:500; color:#eee; }
              input { font-size:32px; width:140px; text-align:center; padding:8px;
                      border-radius:8px; border:1px solid #444; background:#111; color:#fff;
                      letter-spacing:8px; }
              button { font-size:17px; margin-top:18px; padding:10px 28px; border-radius:8px;
                       border:0; background:#0a84ff; color:#fff; }
              .err { color:#ff6b6b; }
            </style></head><body>
            <h1>Enter the pairing code</h1>
            <p>It's shown in the iPadScreen app on your Mac.</p>
            \(note)
            <form method="get" action="/">
              <input name="code" type="text" pattern="[0-9]*" maxlength="4" autocomplete="off"><br>
              <button type="submit">Connect</button>
            </form>
            </body></html>
            """
    }

    /// Remote IP of a connection, used as the key for attempt counting.
    private static func remoteAddress(_ conn: NWConnection) -> String {
        if case let .hostPort(host, _) = conn.endpoint { return "\(host)" }
        return "unknown"
    }

    /// Reads a query parameter from the request line.
    private static func queryValue(_ name: String, in request: String) -> String? {
        guard let firstLine = request.components(separatedBy: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, let query = parts[1].split(separator: "?", maxSplits: 1).dropFirst().first
        else { return nil }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == name { return String(kv[1]) }
        }
        return nil
    }

    // MARK: - Routing

    private func handle(_ conn: NWConnection) {
        // Read the request, then route it by path.
        //
        // `self` is captured strongly: if the server were released while a
        // connection is in progress, the request would silently drop.
        conn.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                readRequest(conn, accumulated: Data())
            case .failed(let error):
                Log.debug("Connection error: \(error)")
                conn.cancel()
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    /// Keeps reading until the full request headers (`\r\n\r\n`) arrive.
    ///
    /// A single `receive` isn't enough: Chrome and iOS Safari routinely split
    /// a request across several TCP packets on a real network, and routing
    /// on the first fragment sends the request down the wrong path.
    private func readRequest(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, isComplete, error in
            guard error == nil else {
                conn.cancel()
                return
            }

            var buffer = accumulated
            if let data { buffer.append(data) }

            guard !buffer.isEmpty else {
                if isComplete { conn.cancel() }
                return
            }

            // Headers not complete yet; wait for the rest.
            guard buffer.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if isComplete {
                    conn.cancel()
                } else if buffer.count < 64 * 1024 {
                    readRequest(conn, accumulated: buffer)
                } else {
                    // No sane request header is this big.
                    conn.cancel()
                }
                return
            }

            guard let request = String(data: buffer, encoding: .utf8) else {
                conn.cancel()
                return
            }

            let path = Self.requestPath(request)
            // Only the browser paths use the code in the URL; the native app
            // authenticates inside its stream.
            let auth = path == "/raw" ? .missing : authorize(conn, request: request)
            switch path {
            case "/stream":
                // Browser: MJPEG
                guard auth == .ok else { return reject(conn, status: "403 Forbidden") }
                guard hasRoomForClient else { return reject(conn, status: "503 Service Unavailable") }
                startStream(conn)
            case "/raw":
                // Native app. Authentication happens in the stream itself
                // (see PairingCrypto), not with a code in the URL.
                //
                // An iPad may ask for USB before it's authenticated. Honoring
                // that only opens the USB tunnel, which gives no access to the
                // picture; it's how an unpaired iPad gets onto the cable. The
                // opposite (forcing Wi-Fi) isn't taken unauthenticated: it
                // would cut off whoever is on USB.
                if Self.queryValue("mode", in: request) == LinkMode.usb.rawValue {
                    onModeRequest?(.usb)
                }
                guard let deviceID = Self.queryValue("id", in: request),
                      let clientNonce = Self.queryValue("cn", in: request),
                      PairingCrypto.isHex(deviceID, length: 32),
                      PairingCrypto.isHex(clientNonce, length: 32)
                else { return reject(conn, status: "400 Bad Request") }
                guard hasRoomForClient else { return reject(conn, status: "503 Service Unavailable") }
                startRawStream(conn, deviceID: deviceID, clientNonce: clientNonce)
            default:
                serveHTTP(conn, request: request, auth: auth)
            }
        }
    }

    /// Extracts the path from the request line: "GET /stream HTTP/1.1" → "/stream"
    private static func requestPath(_ request: String) -> String {
        guard let firstLine = request.components(separatedBy: "\r\n").first else { return "/" }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return "/" }
        return String(parts[1]).components(separatedBy: "?").first ?? "/"
    }

    /// Raw stream for the native app. Unlike the browser stream it uses a
    /// fixed-size binary header instead of HTTP part headers.
    /// Wi-Fi clients still in their handshake. They're kept alive here but
    /// not in `clients`: they get no frames and don't count as connected.
    private var pendingNative: [Int: RawStreamClient] = [:]

    private func startRawStream(_ conn: NWConnection, deviceID: String, clientNonce: String) {
        clientsLock.lock()
        let id = nextClientID
        nextClientID += 1
        clientsLock.unlock()

        let client = RawStreamClient(connection: conn, id: id, deviceID: deviceID,
                                     clientNonce: clientNonce,
                                     address: Self.remoteAddress(conn), authority: self)
        client.onControl = { [weak self] message in
            self?.handleControl(message)
        }
        client.onAuthenticated = { [weak self] client in
            guard let self else { return }
            self.clientsLock.lock()
            self.pendingNative.removeValue(forKey: client.id)
            // USB already carries the stream; a second copy over Wi-Fi would
            // halve the iPad's decode capacity.
            if self.usbActive {
                self.clientsLock.unlock()
                Log.info("iPad \(client.id) authenticated over Wi-Fi while USB is up; closing it")
                client.close()
                return
            }
            self.clients[client.id] = client
            let count = self.clients.count
            self.clientsLock.unlock()
            Log.success("iPad \(client.id) connected over Wi-Fi (\(count) connected)")
            self.onClientCountChanged?(count)
        }
        client.onClose = { [weak self] closedID in
            guard let self else { return }
            self.clientsLock.lock()
            self.pendingNative.removeValue(forKey: closedID)
            let existed = self.clients.removeValue(forKey: closedID) != nil
            let count = self.clients.count
            self.clientsLock.unlock()
            if existed {
                Log.info("Client \(closedID) disconnected (\(count) connected)")
                self.onClientCountChanged?(count)
            }
        }

        clientsLock.lock()
        pendingNative[id] = client
        let currentMode = mode
        clientsLock.unlock()

        client.start(width: pageConfig.width, height: pageConfig.height, mode: currentMode)
    }

    private func startStream(_ conn: NWConnection) {
        clientsLock.lock()
        let id = nextClientID
        nextClientID += 1
        clientsLock.unlock()

        let client = MJPEGClient(connection: conn, id: id)
        client.onClose = { [weak self] closedID in
            guard let self else { return }
            self.clientsLock.lock()
            let existed = self.clients.removeValue(forKey: closedID) != nil
            let count = self.clients.count
            self.clientsLock.unlock()
            if existed {
                Log.info("Client \(closedID) disconnected (\(count) connected)")
                self.onClientCountChanged?(count)
            }
        }

        clientsLock.lock()
        clients[id] = client
        clientsLock.unlock()

        Log.success("Client \(id) connected (\(clientCount) connected)")
        onClientCountChanged?(clientCount)

        client.start()

        // Show the current screen right away instead of waiting for it to
        // change.
        clientsLock.lock()
        let last = lastFrame
        clientsLock.unlock()
        if let last { client.send(last) }
    }

    // MARK: - Static files

    private func serveHTTP(_ conn: NWConnection, request: String, auth: AuthResult) {
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let rawPath = parts.count >= 2 ? String(parts[1]) : "/"
        let path = rawPath.components(separatedBy: "?").first ?? "/"

        let body: Data
        let contentType: String

        switch path {
        case "/", "/index.html":
            // Without the right code, show a code entry form instead of the
            // viewer; the viewer page itself would leak nothing, but the
            // stream URL it points at needs the code anyway.
            let page = (auth == .ok) ? renderPage() : codePage(auth)
            body = Data(page.utf8)
            contentType = "text/html; charset=utf-8"

        case "/favicon.ico":
            // iOS 6 Safari asks for it several times per page; an empty reply will do.
            body = Data()
            contentType = "image/x-icon"

        default:
            let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                conn.cancel()
            })
            return
        }

        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        // iOS 6 caches aggressively; make it fetch the page fresh every time.
        header += "Cache-Control: no-cache, no-store, must-revalidate\r\n"
        header += "Pragma: no-cache\r\n"
        header += "Connection: close\r\n\r\n"

        var payload = Data(header.utf8)
        payload.append(body)

        conn.send(content: payload, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    private func renderPage() -> String {
        let templateURL = webRoot.appendingPathComponent("viewer.html")
        guard var html = try? String(contentsOf: templateURL, encoding: .utf8) else {
            Log.error("viewer.html not found: \(templateURL.path)")
            return """
                <html><body style="font:14px -apple-system;padding:40px;background:#000;color:#ccc">
                <h3>Incomplete install</h3>
                <p>viewer.html was not found. Expected at:</p>
                <p style="font-family:monospace;font-size:12px">\(templateURL.path)</p>
                </body></html>
                """
        }
        // Fit the picture to the iPad's 4:3 screen without distortion. If
        // the virtual display is wider, width fills the screen; if narrower,
        // height does; the rest is letterboxed. Percentages keep it right
        // even when Safari's toolbars eat into the viewport.
        let panelRatio = 1024.0 / 768.0
        let frameRatio = Double(pageConfig.width) / Double(pageConfig.height)

        let viewW: Double, viewH: Double
        if frameRatio >= panelRatio {
            viewW = 100
            viewH = 100 * (panelRatio / frameRatio)
        } else {
            viewW = 100 * (frameRatio / panelRatio)
            viewH = 100
        }

        // Keeping decimals avoids one-pixel shifts from rounding.
        func fmt(_ v: Double) -> String { String(format: "%.3f", v) }

        html = html.replacingOccurrences(of: "{{VIEW_W}}", with: fmt(viewW))
        html = html.replacingOccurrences(of: "{{VIEW_H}}", with: fmt(viewH))
        html = html.replacingOccurrences(of: "{{OFFSET_X}}", with: fmt((100 - viewW) / 2))
        html = html.replacingOccurrences(of: "{{OFFSET_Y}}", with: fmt((100 - viewH) / 2))
        html = html.replacingOccurrences(of: "{{CODE}}", with: currentPairingCode)
        return html
    }

    // MARK: - Heartbeat

    /// Pings native clients every couple of seconds and drops the ones that
    /// have gone quiet. Without it a connection that died without a clean
    /// close (Wi-Fi out of range, iPad asleep) stayed "connected" forever;
    /// on a static screen there's no traffic that would reveal it.
    private var heartbeat: DispatchSourceTimer?
    private let silenceLimit: TimeInterval = 8

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.beat() }
        timer.resume()
        heartbeat = timer
    }

    private func beat() {
        clientsLock.lock()
        let native = clients.values.filter { $0 is RawStreamClient || $0 is USBSender }
        clientsLock.unlock()

        let now = Date()
        for client in native {
            let heard = (client as? RawStreamClient)?.lastHeard ?? (client as? USBSender)?.lastHeard ?? now
            if now.timeIntervalSince(heard) > silenceLimit {
                Log.info("Client \(client.id) went quiet; closing")
                client.close()
            } else {
                client.sendControl("ping")
            }
        }
    }
}

extension StreamServer: PairingAuthority {

    func deviceKey(for deviceID: String) -> Data? {
        Settings.shared.deviceKey(for: deviceID)
    }

    func issueDeviceKey(for deviceID: String) -> Data {
        let key = PairingCrypto.data(fromHex: PairingCrypto.randomHex(bytes: 32))!
        Settings.shared.storeDeviceKey(key, for: deviceID)
        return key
    }

    var latestFrame: EncodedFrame? {
        clientsLock.lock(); defer { clientsLock.unlock() }
        return lastFrame
    }
}
