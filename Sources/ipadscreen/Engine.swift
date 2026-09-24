import Foundation
import ScreenCaptureKit
import AppKit

/// Runs capture, the server and the USB bridge together.
///
/// Used the same way from headless mode and from the UI; the UI only
/// changes settings and reads state.
@MainActor
final class Engine {

    private var server: StreamServer?
    private var capture: ScreenCaptureEngine?
    private var iproxy: Process?
    private var healthTimer: Timer?

    private var currentDisplay: SCDisplay?
    private var displays: [SCDisplay] = []

    /// Receives status for the UI. Stays nil in headless mode.
    weak var state: AppState?

    private(set) var isRunning = false

    /// Link mode in effect, shared with the iPad app.
    private var linkMode: LinkMode = Settings.shared.useUSB ? .usb : .wifi

    // Measurement
    private var lastFrameCount: UInt64 = 0
    private var lastByteCount: UInt64 = 0
    private var lastSampleTime = Date()

    // MARK: - Displays

    func loadDisplays() async throws {
        displays = try await ScreenCaptureEngine.availableDisplays()
        state?.availableDisplays = displays.map { d in
            AppState.DisplayInfo(
                id: d.displayID,
                name: displayName(d),
                width: d.width,
                height: d.height,
                isVirtual: isVirtualDisplay(d))
        }

        // Is the saved selection still valid?
        let saved = Settings.shared.displayID
        if saved != 0, displays.contains(where: { $0.displayID == saved }) {
            state?.selectedDisplayID = saved
        } else if let auto = pickDefaultDisplay() {
            state?.selectedDisplayID = auto.displayID
        }
    }

    /// Only ever picks a virtual display on its own. Falling back to the
    /// smallest physical monitor used to mean that, with BetterDisplay not
    /// running, a real screen could end up streamed without anyone choosing
    /// it. A physical display is still used if the user picks it.
    private func pickDefaultDisplay() -> SCDisplay? {
        displays.first(where: { isVirtualDisplay($0) })
    }

    // MARK: - Start / stop

    func start() async throws {
        guard !isRunning else { return }

        let settings = Settings.shared

        let display: SCDisplay
        if settings.displayID != 0,
           let found = displays.first(where: { $0.displayID == settings.displayID }) {
            display = found
        } else if let auto = pickDefaultDisplay() {
            display = auto
        } else {
            throw EngineError.noDisplay
        }
        currentDisplay = display

        // With no explicit scale, bring a HiDPI display down to its logical size.
        var scale = settings.scale
        if let auto = autoScale(for: display), scale == 1.0 {
            scale = auto
        }

        let width = evenDimension(Double(display.width) * scale)
        let height = evenDimension(Double(display.height) * scale)

        linkMode = settings.useUSB ? .usb : .wifi
        let server = StreamServer(
            port: settings.port,
            webRoot: resolveWebRoot(),
            config: .init(width: width, height: height, fps: settings.fps),
            mode: linkMode,
            pairingCode: settings.pairingCode)

        let capture = ScreenCaptureEngine()

        capture.onFrame = { [weak server, weak capture] frame in
            guard let server, let capture else { return }
            server.broadcast(frame)
            capture.reportBacklog(server.maxPendingWrites)
        }

        server.onClientCountChanged = { [weak self] count in
            Task { @MainActor in
                self?.state?.clientCount = count
            }
        }

        // The iPad changed the link mode from its own panel.
        server.onModeRequest = { [weak self] requested in
            Task { @MainActor in
                Log.info("iPad asked for \(requested.rawValue)")
                self?.setLinkMode(requested)
            }
        }

        try server.start()
        try await capture.start(display: display, targetFPS: settings.fps, scale: scale)

        capture.setQuality(settings.autoQuality ? nil : settings.quality,
                           auto: settings.autoQuality)

        self.server = server
        self.capture = capture

        if linkMode == .usb {
            capture.useDeepQueueThresholds(true)
            startUSBTunnel(server: server)
        }

        state?.frameSize = CGSize(width: width, height: height)
        state?.connection = .wifi
        state?.isRunning = true
        state?.statusText = ""
        isRunning = true

        startHealthTimer()
        Log.info("Mirroring started: \(width)×\(height) @ \(settings.fps) fps")
    }

    func stop() async {
        guard isRunning else { return }

        healthTimer?.invalidate()
        healthTimer = nil

        await capture?.stop()
        server?.stop()
        iproxy?.terminate()
        usbStopWork?.cancel()
        usbStopWork = nil

        capture = nil
        server = nil
        iproxy = nil

        isRunning = false
        state?.isRunning = false
        state?.clientCount = 0
        state?.currentFPS = 0
        Log.info("Mirroring stopped")
    }

    // MARK: - Live setting changes

    /// Frame rate can change without interrupting the stream.
    func applyFrameRate() async {
        await capture?.updateFrameRate(Settings.shared.fps)
    }

    func applyQuality() {
        let s = Settings.shared
        capture?.setQuality(s.autoQuality ? nil : s.quality, auto: s.autoQuality)
    }

    /// Scale changes the resolution, so the stream has to be rebuilt; there
    /// is a brief interruption.
    func applyScale() async {
        guard isRunning else { return }
        await stop()
        try? await start()
    }

    /// Picks a new pairing code and forgets every paired iPad. Wi-Fi viewers
    /// are disconnected and have to pair again, over USB or with the new code.
    func regeneratePairingCode() {
        Settings.shared.forgetAllDevices()
        let code = Settings.shared.regeneratePairingCode()
        state?.pairingCode = code
        server?.setPairingCode(code)
        Log.info("New pairing code; paired iPads forgotten, Wi-Fi viewers disconnected")
    }

    /// The Wi-Fi/USB picker on the Mac changed.
    func applyConnectionMode() async {
        setLinkMode(Settings.shared.useUSB ? .usb : .wifi)
    }

    /// Switches the link mode on both sides without restarting the stream.
    ///
    /// Called from the Mac's picker and when the iPad asks for a change, so
    /// the two stay in sync: the new mode is saved, shown in the UI, and sent
    /// to the iPad, which switches its own picker and connection to match.
    func setLinkMode(_ newMode: LinkMode) {
        guard newMode != linkMode else { return }
        linkMode = newMode

        // Keep the stored setting and the Mac's picker in line. Setting the
        // picker calls back into applyConnectionMode, which the guard above
        // turns into a no-op.
        Settings.shared.useUSB = (newMode == .usb)
        if state?.useUSB != (newMode == .usb) { state?.useUSB = (newMode == .usb) }

        guard isRunning, let server else { return }
        server.setMode(newMode)
        capture?.useDeepQueueThresholds(newMode == .usb)

        switch newMode {
        case .usb:
            usbStopWork?.cancel()
            usbStopWork = nil
            startUSBTunnel(server: server)
        case .wifi:
            // Give the mode message a moment to reach the iPad over USB
            // before the tunnel goes away, so it switches to Wi-Fi instead of
            // just seeing the cable connection drop.
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.stopUSBTunnel() }
            }
            usbStopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    private var usbStopWork: DispatchWorkItem?

    // MARK: - USB

    private func startUSBTunnel(server: StreamServer) {
        let port: UInt16 = 8766
        if iproxy?.isRunning == true {
            server.enableUSB(localPort: port)
            return
        }
        guard let path = findExecutable("iproxy") else {
            Log.error("iproxy not found — brew install libimobiledevice")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["\(port)", "\(port)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            iproxy = proc
            // iproxy takes a moment to open its port.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                server.enableUSB(localPort: port)
            }
        } catch {
            Log.error("Could not start iproxy: \(error.localizedDescription)")
        }
    }

    private func stopUSBTunnel() {
        server?.disableUSB()
        iproxy?.terminate()
        iproxy = nil
        state?.connection = .wifi
    }

    // MARK: - Sleep

    /// After the Mac sleeps and wakes, the capture stream can be dead.
    /// Rebuild it on wake; otherwise the app looks like it's running but
    /// produces no frames.
    func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.wasRunningBeforeSleep = true
                await self.stop()
            }
        }

        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wasRunningBeforeSleep else { return }
                self.wasRunningBeforeSleep = false
                // The display layout may have changed while asleep.
                try? await self.loadDisplays()
                try? await self.start()
            }
        }
    }

    private var wasRunningBeforeSleep = false

    // MARK: - Measurement

    private func startHealthTimer() {
        lastFrameCount = 0
        lastByteCount = 0        // not resetting this skewed the first sample
        lastSampleTime = Date()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func sample() {
        guard let capture, let server else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(lastSampleTime)
        guard elapsed > 0 else { return }

        let frames = capture.frameCount
        let bytes = server.bytesSent

        // Counters reset on restart and can be smaller than the previous
        // value. Unsigned subtraction then overflows, which Swift turns into
        // a crash; that's exactly what happened on stop/start after sleep.
        let frameDelta = frames >= lastFrameCount ? frames - lastFrameCount : frames
        let byteDelta = bytes >= lastByteCount ? bytes - lastByteCount : bytes

        let fps = Double(frameDelta) / elapsed
        let mbps = Double(byteDelta) * 8.0 / elapsed / 1e6

        lastFrameCount = frames
        lastByteCount = bytes
        lastSampleTime = now

        // USB may be selected while the tunnel is down; the UI should show
        // the link actually in use.
        state?.connection = server.usbActive ? .usb : .wifi
        state?.recordSample(fps: fps, quality: capture.currentQuality, mbps: mbps)

        if Log.verbose {
            Log.debug(String(format: "%.0f fps, quality %.0f%%, %.1f Mbps",
                             fps, capture.currentQuality * 100, mbps))
        }
    }
}

enum EngineError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No virtual display found. Create one in BetterDisplay, or pick a display in Settings."
        }
    }
}

// MARK: - Helpers

func evenDimension(_ value: Double) -> Int {
    let v = Int(value)
    return v - (v % 2)
}
