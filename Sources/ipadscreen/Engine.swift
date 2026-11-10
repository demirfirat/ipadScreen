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
    private var cursorStream: CursorStream?
    private var touchInput: TouchInput?
    private var iproxy: Process?
    private var healthTimer: Timer?

    private var currentDisplay: SCDisplay?
    private var displays: [SCDisplay] = []

    /// The display this app created, if any. It has to stay alive for the
    /// screen to exist, so the engine owns it rather than the capture side.
    private let virtualDisplay = VirtualDisplay()

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
        publishDisplays()

        // Is the saved selection still valid?
        let saved = Settings.shared.displayID
        if saved != 0, displays.contains(where: { $0.displayID == saved }) {
            state?.selectedDisplayID = saved
        } else if let auto = pickDefaultDisplay() {
            state?.selectedDisplayID = auto.displayID
        }
    }

    /// Copies the display list into the UI state.
    private func publishDisplays() {
        state?.availableDisplays = displays.map { d in
            AppState.DisplayInfo(
                id: d.displayID,
                name: displayName(d),
                width: d.width,
                height: d.height,
                isVirtual: isVirtualDisplay(d))
        }
    }

    /// Only ever picks a virtual display on its own. Falling back to the
    /// smallest physical monitor used to mean that, with no virtual display
    /// around, a real screen could end up streamed without anyone choosing
    /// it. A physical display is still used if the user picks it.
    private func pickDefaultDisplay() -> SCDisplay? {
        displays.first(where: { isVirtualDisplay($0) })
    }

    // MARK: - Virtual display

    /// Detects the attached iPad so the display this app creates matches its
    /// panel. Falls back to the model seen last time, then to an iPad 2.
    private func detectIPadModel() async -> IPadModel {
        let detected = await Task.detached(priority: .userInitiated) {
            IPadModel.detect()
        }.value

        if let detected { Settings.shared.iPadModel = detected }
        let model = detected ?? Settings.shared.iPadModel
        state?.iPadModelLabel = "\(model.name) — \(model.width)×\(model.height)"
        return model
    }

    /// The display to mirror.
    ///
    /// Order: what the user picked, then a virtual display that already
    /// exists (this app's from before, BetterDisplay's, …), and finally one
    /// this app creates. That last step is why nothing else needs installing:
    /// ScreenCaptureKit can only capture a display that exists, so when there
    /// isn't a spare one the app makes its own.
    private func resolveDisplay(for model: IPadModel) async throws -> SCDisplay {
        let saved = Settings.shared.displayID
        if saved != 0, let chosen = displays.first(where: { $0.displayID == saved }) {
            return chosen
        }
        if let existing = displays.first(where: { isVirtualDisplay($0) }) {
            // A display this app made before — an earlier run, or one it left
            // behind — still obeys the side setting. Another app's virtual
            // screen stays where its owner put it.
            if isOurDisplay(existing) {
                VirtualDisplay.place(displayID: existing.displayID,
                                     width: existing.width,
                                     beside: Settings.shared.displaySide)
            }
            return existing
        }

        guard let created = virtualDisplay.create(width: model.width, height: model.height,
                                                 side: Settings.shared.displaySide) else {
            throw EngineError.noDisplay
        }
        Log.info("Created a \(model.width)×\(model.height) virtual display for \(model.name)")

        // The window server brings a new display online asynchronously, and
        // ScreenCaptureKit doesn't list it until then.
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            displays = try await ScreenCaptureEngine.availableDisplays()
            if let display = displays.first(where: { $0.displayID == created }) {
                // The display is in the arrangement now, so a move that was
                // attempted before it came online can be made for real.
                VirtualDisplay.place(displayID: created, width: display.width,
                                     beside: Settings.shared.displaySide)
                publishDisplays()
                state?.selectedDisplayID = display.displayID
                return display
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        virtualDisplay.destroy()
        throw EngineError.noDisplay
    }

    // MARK: - Start / stop

    func start() async throws {
        guard !isRunning else { return }

        let settings = Settings.shared

        let model = await detectIPadModel()
        let display = try await resolveDisplay(for: model)
        currentDisplay = display

        // A virtual display of ours that isn't the one being mirrored would
        // just be an extra empty screen in the arrangement.
        if virtualDisplay.isActive, virtualDisplay.displayID != display.displayID {
            virtualDisplay.destroy()
        }

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

        // Touches on the iPad become clicks on the display being mirrored.
        let touch = TouchInput(displayID: display.displayID)
        server.onTouch = { message in touch.handle(message) }

        let capture = ScreenCaptureEngine()

        capture.onFrame = { [weak server, weak capture] frame in
            guard let server, let capture else { return }
            server.broadcast(frame)
            // A refinement is one large frame; judging congestion by it
            // would needlessly push the live quality down.
            if !frame.isRefinement {
                capture.reportBacklog(server.maxPendingWrites, dropped: server.droppedFrames)
            }
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

        // The iPad's own decode numbers, once a second. It's the only side
        // that can tell a slow link from a slow decoder; see `ClientStats`.
        server.onStats = { [weak self, weak capture] stats in
            capture?.reportClientStats(stats)
            Task { @MainActor in
                self?.state?.clientDecodeMS = stats.decodeMS
                self?.state?.clientFPS = stats.fps
            }
        }

        try server.start()
        try await capture.start(display: display, targetFPS: settings.fps, scale: scale)

        capture.setQuality(settings.autoQuality ? nil : settings.quality,
                           auto: settings.autoQuality)

        self.server = server
        self.capture = capture

        let cursor = CursorStream(
            displayID: display.displayID, frameWidth: width,
            isActive: { [weak server] in server?.cursorOverlayAvailable ?? false },
            onActiveChanged: { [weak capture] active in
                Task { await capture?.setShowsCursor(!active) }
            },
            send: { [weak server] in server?.broadcastControl($0) })
        cursor.start()
        cursorStream = cursor

        touch.start()
        touchInput = touch

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

    /// Stops mirroring. The virtual display goes away with it, unless a
    /// restart follows immediately: recreating it for a scale change would
    /// send every window on it back to the main screen.
    func stop(keepVirtualDisplay: Bool = false) async {
        guard isRunning else { return }

        healthTimer?.invalidate()
        healthTimer = nil

        cursorStream?.stop()
        cursorStream = nil
        touchInput?.stop()
        touchInput = nil
        await capture?.stop()
        server?.stop()
        iproxy?.terminate()
        usbStopWork?.cancel()
        usbStopWork = nil

        capture = nil
        server = nil
        iproxy = nil
        currentDisplay = nil

        if !keepVirtualDisplay { virtualDisplay.destroy() }

        isRunning = false
        state?.isRunning = false
        state?.clientCount = 0
        state?.currentFPS = 0
        state?.clientFPS = 0
        state?.clientDecodeMS = 0
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
        await stop(keepVirtualDisplay: true)
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

    /// Moves the display this app owns when the side setting changes.
    ///
    /// Nothing happens for a display picked by hand: moving someone else's
    /// screen (a monitor, or another app's virtual display) would be rude.
    func applyDisplaySide() {
        let side = Settings.shared.displaySide
        if virtualDisplay.isActive {
            virtualDisplay.place(beside: side)
            return
        }
        // A display named after this app that this run didn't create is still
        // ours to move; a screen someone else owns stays where it is.
        guard let display = currentDisplay, isOurDisplay(display) else { return }
        VirtualDisplay.place(displayID: display.displayID, width: display.width, beside: side)
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
            Log.debug(String(format: "%.0f fps, quality %.0f%%, %.1f Mbps, iPad %.0f fps at %.1f ms",
                             fps, capture.currentQuality * 100, mbps,
                             state?.clientFPS ?? 0, state?.clientDecodeMS ?? 0))
        }
    }
}

enum EngineError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "Couldn't create a virtual display. Try again, or pick a display in Settings."
        }
    }
}

// MARK: - Helpers

func evenDimension(_ value: Double) -> Int {
    let v = Int(value)
    return v - (v % 2)
}
