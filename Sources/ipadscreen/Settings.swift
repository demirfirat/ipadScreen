import Foundation

/// Settings that can change while the app is running.
///
/// Changes from the UI go straight to the capture and streaming side, so
/// frame rate, quality and scale can change without a restart. Values are
/// stored in `UserDefaults` so the next launch picks up where we left off.
final class Settings {

    static let shared = Settings()

    /// Called whenever a setting changes. The engine and the UI subscribe.
    var onChange: ((Settings) -> Void)?

    private let defaults = UserDefaults.standard
    private let lock = NSLock()

    private enum Key {
        static let fps = "fps"
        static let quality = "quality"
        static let autoQuality = "autoQuality"
        static let scale = "scale"
        static let useUSB = "useUSB"
        static let displayID = "displayID"
        static let port = "port"
        static let pairingCode = "pairingCode"
        static let pairedDevices = "pairedDevices"
    }

    private init() {
        defaults.register(defaults: [
            Key.fps: 45,
            Key.quality: 0.52,
            Key.autoQuality: true,
            Key.scale: 1.0,
            // USB first: with the cable attached the iPad connects without a
            // pairing code; without it the stream falls back to Wi-Fi.
            Key.useUSB: true,
            Key.port: 8765,
        ])
    }

    // MARK: - Settings

    /// Target frame rate. The iPad 2 takes ~20 ms to decode a frame, so
    /// anything above 45 has no effect in practice.
    var fps: Int {
        get { read { defaults.integer(forKey: Key.fps) } }
        set { write { defaults.set(max(1, min(60, newValue)), forKey: Key.fps) } }
    }

    /// JPEG quality (0-1). With `autoQuality` on, the controller keeps
    /// updating this; with it off, it stays at the user's value.
    var quality: Double {
        get { read { defaults.double(forKey: Key.quality) } }
        set { write { defaults.set(max(0.1, min(0.95, newValue)), forKey: Key.quality) } }
    }

    /// Whether quality adjusts automatically. When off, the user's value holds.
    var autoQuality: Bool {
        get { read { defaults.bool(forKey: Key.autoQuality) } }
        set { write { defaults.set(newValue, forKey: Key.autoQuality) } }
    }

    /// Capture scale (0.25-1.0). It directly drives decode cost on the
    /// iPad, so it's the setting that affects frame rate the most.
    var scale: Double {
        get { read { defaults.double(forKey: Key.scale) } }
        set { write { defaults.set(max(0.25, min(1.0, newValue)), forKey: Key.scale) } }
    }

    var useUSB: Bool {
        get { read { defaults.bool(forKey: Key.useUSB) } }
        set { write { defaults.set(newValue, forKey: Key.useUSB) } }
    }

    /// ID of the mirrored display. 0 means pick automatically.
    var displayID: UInt32 {
        get { read { UInt32(defaults.integer(forKey: Key.displayID)) } }
        set { write { defaults.set(Int(newValue), forKey: Key.displayID) } }
    }

    var port: UInt16 {
        get { read { UInt16(defaults.integer(forKey: Key.port)) } }
        set { write { defaults.set(Int(newValue), forKey: Key.port) } }
    }

    /// Four-digit code a device has to present to receive the stream over
    /// Wi-Fi. Created on first use and kept until regenerated.
    var pairingCode: String {
        if let code = read({ defaults.string(forKey: Key.pairingCode) }), code.count == 4 {
            return code
        }
        return regeneratePairingCode()
    }

    /// Picks a new random code. Devices paired with the old one have to
    /// enter the new one.
    @discardableResult
    func regeneratePairingCode() -> String {
        let code = String(format: "%04d", Int.random(in: 0...9999))
        write { defaults.set(code, forKey: Key.pairingCode) }
        return code
    }

    // MARK: - Paired devices

    /// Device keys of paired iPads, by device ID. Stored in the app's
    /// defaults; anyone who can read this Mac's user files could impersonate
    /// a paired iPad, but they could also just look at the screen.
    func deviceKey(for deviceID: String) -> Data? {
        let all = read { defaults.dictionary(forKey: Key.pairedDevices) as? [String: String] } ?? [:]
        return all[deviceID].flatMap(PairingCrypto.data(fromHex:))
    }

    func storeDeviceKey(_ key: Data, for deviceID: String) {
        write {
            var all = defaults.dictionary(forKey: Key.pairedDevices) as? [String: String] ?? [:]
            all[deviceID] = key.map { String(format: "%02x", $0) }.joined()
            defaults.set(all, forKey: Key.pairedDevices)
        }
    }

    /// Unpairs every iPad; each has to pair again (over USB, or with the PIN).
    func forgetAllDevices() {
        write { defaults.removeObject(forKey: Key.pairedDevices) }
    }

    // MARK: - Helpers

    private func read<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func write(_ body: () -> Void) {
        lock.lock()
        body()
        lock.unlock()
        onChange?(self)
    }

    /// Applies command-line arguments. Arguments that were given overwrite
    /// the stored values, so they persist into later launches too.
    func applyCommandLine(_ options: Options) {
        lock.lock()
        if options.fpsWasSet { defaults.set(options.fps, forKey: Key.fps) }
        if options.scaleWasSet { defaults.set(options.scale, forKey: Key.scale) }
        if options.useUSB { defaults.set(true, forKey: Key.useUSB) }
        defaults.set(Int(options.port), forKey: Key.port)
        lock.unlock()
    }
}
