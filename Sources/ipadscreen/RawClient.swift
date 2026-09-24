import Foundation
import Network
import CryptoKit
import Security

/// How the Mac and the iPad app are connected. It's a single setting shared
/// by both sides: changing it on either one changes it on the other.
enum LinkMode: String {
    /// Wi-Fi only.
    case wifi
    /// USB when the cable is attached, Wi-Fi otherwise.
    case usb
}

/// The raw stream protocol shared by the Wi-Fi and USB paths.
///
/// Mac → iPad:
///
///     [ 8 bytes ]  magic "IPSCRN03"
///     [ 4 bytes ]  width   (big-endian uint32)
///     [ 4 bytes ]  height  (big-endian uint32)
///     then any number of packets:
///     [ 4 bytes ]  length (big-endian uint32)
///     [ n bytes ]  payload
///
/// If the top bit of the length is clear, the payload is a JPEG frame. If
/// it's set, the payload is a UTF-8 control message such as "mode=usb", and
/// the remaining 31 bits are its length.
///
/// iPad → Mac: newline-terminated UTF-8 control messages.
///
/// See `PairingCrypto` for how a Wi-Fi connection is authenticated.
///
/// Big-endian because that's the convention for network protocols, and the
/// iOS side decodes it with a single `ntohl`.
enum RawProtocol {

    /// Fixed signature so the client can tell it reached the right server.
    /// Bumped whenever the protocol changes incompatibly (02: control
    /// messages, 03: device keys and mutual authentication), so mismatched
    /// versions refuse each other instead of misparsing.
    static let magic = "IPSCRN03"

    private static let controlFlag: UInt32 = 0x8000_0000

    static func header(width: Int, height: Int) -> Data {
        var data = Data(magic.utf8)
        data.append(uint32BE(UInt32(width)))
        data.append(uint32BE(UInt32(height)))
        return data
    }

    static func framePacket(_ jpeg: Data) -> Data {
        var packet = uint32BE(UInt32(jpeg.count))
        packet.append(jpeg)
        return packet
    }

    static func controlPacket(_ message: String) -> Data {
        let payload = Data(message.utf8)
        var packet = uint32BE(UInt32(payload.count) | controlFlag)
        packet.append(payload)
        return packet
    }

    static func modeMessage(_ mode: LinkMode) -> String { "mode=\(mode.rawValue)" }

    /// Parses "mode=usb" and the like; nil for anything else.
    static func mode(from message: String) -> LinkMode? {
        guard message.hasPrefix("mode=") else { return nil }
        return LinkMode(rawValue: String(message.dropFirst(5)))
    }

    private static func uint32BE(_ value: UInt32) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 4)
    }
}

/// Authentication for the Wi-Fi stream.
///
/// A four-digit PIN can't protect a connection on its own: anyone who sees a
/// response derived from it can try all 10,000 PINs offline in no time. So
/// the PIN is only used once, to pair. Pairing hands the iPad a random
/// 256-bit device key, and every later connection proves knowledge of that
/// key in both directions:
///
///     iPad → Mac   GET /raw?id=<device id>&cn=<client nonce>
///     Mac → iPad   hello=<server nonce>:<HMAC(key, "S:cn:sn")>
///     iPad → Mac   proof=<HMAC(key, "C:cn:sn")>
///
/// The Mac proves itself first, and the iPad sends nothing if that proof is
/// wrong, so a device impersonating the Mac over Bonjour learns nothing.
///
/// An iPad the Mac doesn't know gets a PIN challenge instead:
///
///     Mac → iPad   pin=<server nonce>
///     iPad → Mac   pin=<HMAC(PIN, "P:cn:sn")>
///     Mac → iPad   key=<new device key>
///
/// Over USB there's no challenge: the cable already means physical access,
/// and an unpaired iPad is given its key there without a PIN. Nonces are 16
/// random bytes, keys 32; all values travel as lowercase hex.
enum PairingCrypto {

    static func randomHex(bytes: Int) -> String {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!)
        }
        precondition(status == errSecSuccess, "no system randomness")
        return hex(data)
    }

    static func proof(key: Data, tag: String, clientNonce: String, serverNonce: String) -> String {
        let message = Data("\(tag):\(clientNonce):\(serverNonce)".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return hex(Data(mac))
    }

    /// Compares in constant time, so response timing doesn't reveal how many
    /// leading characters of a guess were right.
    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    static func isHex(_ s: String, length: Int) -> Bool {
        s.count == length && s.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func data(fromHex s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var data = Data(capacity: s.count / 2)
        var index = s.startIndex
        while index < s.endIndex {
            let next = s.index(index, offsetBy: 2)
            guard let byte = UInt8(s[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// Splits the bytes the iPad sends into newline-terminated messages. TCP can
/// split or merge writes, so a message may arrive in pieces.
struct ControlLineReader {
    private var buffer = Data()

    mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let text = String(data: line, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                lines.append(text)
            }
        }
        // A client that never sends a newline shouldn't grow this forever.
        if buffer.count > 4096 { buffer.removeAll() }
        return lines
    }
}

/// What a Wi-Fi client needs from the server to authenticate.
protocol PairingAuthority: AnyObject {
    func deviceKey(for deviceID: String) -> Data?
    func issueDeviceKey(for deviceID: String) -> Data
    func checkPin(proof: String, clientNonce: String, serverNonce: String,
                  address: String) -> StreamServer.AuthResult
    func recordFailure(_ address: String)
    func isLocked(_ address: String) -> Bool
    var latestFrame: EncodedFrame? { get }
}

/// Streams raw JPEG frames to the native iPad app over Wi-Fi, after the
/// handshake described in `PairingCrypto`.
final class RawStreamClient: FrameSink {

    private enum Handshake {
        case awaitingProof(expected: String)
        case awaitingPin(serverNonce: String)
        case done
        case failed
    }

    private let connection: NWConnection
    let id: Int
    private let deviceID: String
    private let clientNonce: String
    private let address: String
    private weak var authority: PairingAuthority?

    private var isOpen = true
    private let stateLock = NSLock()
    private var inFlight = 0
    private var reader = ControlLineReader()
    private var handshake: Handshake = .failed
    private var mode: LinkMode = .usb

    private var heard = Date()

    var onClose: ((Int) -> Void)?
    /// The handshake succeeded; from now on the client receives frames.
    var onAuthenticated: ((RawStreamClient) -> Void)?
    /// A control message from an authenticated iPad (e.g. "mode=wifi").
    var onControl: ((String) -> Void)?

    init(connection: NWConnection, id: Int, deviceID: String, clientNonce: String,
         address: String, authority: PairingAuthority) {
        self.connection = connection
        self.id = id
        self.deviceID = deviceID
        self.clientNonce = clientNonce
        self.address = address
        self.authority = authority
    }

    var isAuthenticated: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if case .done = handshake { return true }
        return false
    }

    /// When we last heard from the iPad. The heartbeat drops clients that
    /// have gone quiet.
    var lastHeard: Date {
        stateLock.lock(); defer { stateLock.unlock() }
        return heard
    }

    /// Sends the header and the challenge. A known device gets the Mac's
    /// proof first; an unknown one is asked for the PIN.
    func start(width: Int, height: Int, mode: LinkMode) {
        guard let authority else { return close() }
        self.mode = mode

        var hello = RawProtocol.header(width: width, height: height)
        let serverNonce = PairingCrypto.randomHex(bytes: 16)

        if authority.isLocked(address) {
            hello.append(RawProtocol.controlPacket("auth=locked"))
            return sendAndClose(hello)
        }

        stateLock.lock()
        if let key = authority.deviceKey(for: deviceID) {
            let serverProof = PairingCrypto.proof(key: key, tag: "S",
                                                  clientNonce: clientNonce, serverNonce: serverNonce)
            let expected = PairingCrypto.proof(key: key, tag: "C",
                                               clientNonce: clientNonce, serverNonce: serverNonce)
            handshake = .awaitingProof(expected: expected)
            hello.append(RawProtocol.controlPacket("hello=\(serverNonce):\(serverProof)"))
        } else {
            handshake = .awaitingPin(serverNonce: serverNonce)
            hello.append(RawProtocol.controlPacket("pin=\(serverNonce)"))
        }
        stateLock.unlock()

        connection.send(content: hello, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
        receive()

        // Don't hold a slot forever for a client that never answers.
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.isAuthenticated else { return }
            self.close()
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.stateLock.lock()
                self.heard = Date()
                self.stateLock.unlock()
                for line in self.reader.feed(data) { self.handle(line) }
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            self.receive()
        }
    }

    private func handle(_ line: String) {
        if line == "ping" { return }

        stateLock.lock()
        let state = handshake
        stateLock.unlock()

        switch state {
        case .done:
            onControl?(line)

        case .awaitingProof(let expected):
            guard line.hasPrefix("proof=") else { return }
            if PairingCrypto.equal(String(line.dropFirst(6)), expected) {
                authenticated(newKey: nil)
            } else {
                authority?.recordFailure(address)
                fail("auth=wrong")
            }

        case .awaitingPin(let serverNonce):
            guard line.hasPrefix("pin="), let authority else { return }
            switch authority.checkPin(proof: String(line.dropFirst(4)), clientNonce: clientNonce,
                                      serverNonce: serverNonce, address: address) {
            case .ok:
                authenticated(newKey: authority.issueDeviceKey(for: deviceID))
            case .locked:
                fail("auth=locked")
            default:
                fail("auth=wrong")
            }

        case .failed:
            break
        }
    }

    /// Handshake done: hand over the key if this was a pairing, then the
    /// current mode and the latest frame, and start streaming.
    private func authenticated(newKey: Data?) {
        var packet = Data()
        if let newKey {
            packet.append(RawProtocol.controlPacket("key=" + newKey.map { String(format: "%02x", $0) }.joined()))
        }
        packet.append(RawProtocol.controlPacket(RawProtocol.modeMessage(mode)))
        if let frame = authority?.latestFrame { packet.append(RawProtocol.framePacket(frame.data)) }

        stateLock.lock()
        handshake = .done
        stateLock.unlock()

        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
        onAuthenticated?(self)
    }

    private func fail(_ message: String) {
        stateLock.lock()
        handshake = .failed
        stateLock.unlock()
        sendAndClose(RawProtocol.controlPacket(message))
    }

    private func sendAndClose(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    func send(_ frame: EncodedFrame) {
        stateLock.lock()
        guard isOpen, case .done = handshake, inFlight < 2 else {
            stateLock.unlock()
            return
        }
        inFlight += 1
        stateLock.unlock()

        connection.send(content: RawProtocol.framePacket(frame.data),
                        completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.stateLock.lock()
            self.inFlight -= 1
            self.stateLock.unlock()
            if error != nil { self.close() }
        })
    }

    func sendControl(_ message: String) {
        guard isAuthenticated else { return }
        connection.send(content: RawProtocol.controlPacket(message),
                        completion: .contentProcessed { _ in })
    }

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
