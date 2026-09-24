import Foundation
import ScreenCaptureKit
import CoreImage
import CoreVideo
import AppKit

/// A captured frame, JPEG-encoded.
struct EncodedFrame {
    let data: Data
    let width: Int
    let height: Int
    let sequence: UInt64
}

/// Captures a display with ScreenCaptureKit, encodes JPEG, and hands frames
/// to subscribers.
///
/// Both the iPad 2 and its Wi-Fi are slow, so there are two brakes here:
/// `targetFPS` caps the capture rate, and `QualityController` lowers JPEG
/// quality when clients start falling behind.
final class ScreenCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {

    private var stream: SCStream?
    private let ciContext: CIContext
    private let outputQueue = DispatchQueue(label: "ipadscreen.capture", qos: .userInitiated)

    private var sequence: UInt64 = 0
    private let quality = QualityController()

    /// Called for every frame. Fan-out to multiple clients is done by
    /// `StreamServer.broadcast`.
    var onFrame: ((EncodedFrame) -> Void)?

    private(set) var displayWidth: Int = 0
    private(set) var displayHeight: Int = 0

    /// Total frames produced. The health timer uses it to tell whether the
    /// stream has stalled.
    var frameCount: UInt64 {
        countLock.lock(); defer { countLock.unlock() }
        return producedFrames
    }
    private var producedFrames: UInt64 = 0
    private let countLock = NSLock()

    override init() {
        // A Metal-backed CIContext moves JPEG encoding to the GPU.
        // Color management is off: iOS 6 ignores color profiles anyway, and
        // skipping the conversion saves a few milliseconds per frame.
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: options)
        } else {
            ciContext = CIContext(options: options)
        }
        super.init()
    }

    /// Returns every display on the system.
    static func availableDisplays() async throws -> [SCDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        return content.displays
    }

    func start(display: SCDisplay, targetFPS: Int, scale: Double) async throws {
        displayWidth = Int(Double(display.width) * scale)
        displayHeight = Int(Double(display.height) * scale)

        // Round to even dimensions; with odd widths some pixel formats
        // leave a one-pixel artifact on the right edge.
        displayWidth -= displayWidth % 2
        displayHeight -= displayHeight % 2

        activeFrameInterval = CMTime(value: 1, timescale: CMTimeScale(targetFPS))

        let config = SCStreamConfiguration()
        config.width = displayWidth
        config.height = displayHeight
        config.minimumFrameInterval = activeFrameInterval
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 3
        config.scalesToFit = true

        // No window exclusion: everything on the mirrored display should show.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream

        Log.info("Capture started: \(displayWidth)x\(displayHeight) @ \(targetFPS) fps")
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    /// Changes the scale. The resolution changes, so the stream has to be
    /// rebuilt; unlike a frame rate change this causes a brief interruption.
    func restart(display: SCDisplay, targetFPS: Int, scale: Double) async throws {
        await stop()
        try await start(display: display, targetFPS: targetFPS, scale: scale)
    }

    /// Tells the QualityController how far behind the clients are.
    func reportBacklog(_ pending: Int) {
        quality.reportBacklog(pending)
    }

    /// Current JPEG quality (0-1). Shown in diagnostics.
    var currentQuality: Double { quality.currentQuality }

    /// Changes the frame rate without restarting.
    ///
    /// `SCStream` allows updating its configuration while running; doing
    /// that instead of tearing the stream down means a change from the UI
    /// doesn't interrupt the picture.
    func updateFrameRate(_ fps: Int) async {
        guard let stream else { return }
        let config = currentConfiguration
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        try? await stream.updateConfiguration(config)
        Log.debug("Frame rate updated to \(fps)")
    }

    /// Pins quality to a manual value, or hands it back to the controller.
    func setQuality(_ value: Double?, auto: Bool) {
        quality.setManual(auto ? nil : value)
    }

    /// The current capture configuration; changes are applied on top of it.
    private var currentConfiguration: SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = displayWidth
        config.height = displayHeight
        config.minimumFrameInterval = activeFrameInterval
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 3
        config.scalesToFit = true
        return config
    }
    private var activeFrameInterval = CMTime(value: 1, timescale: 45)

    /// Relaxes the quality thresholds for deeper-queued links such as USB.
    func useDeepQueueThresholds(_ deep: Bool) {
        quality.configureForDeepQueue(deep)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // ScreenCaptureKit delivers frames even when nothing changed.
        // Skipping frames that aren't "complete" drops bandwidth to nearly
        // zero on a static screen.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first,
              let statusRaw = first[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete
        else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let jpeg = encodeJPEG(pixelBuffer) else { return }

        sequence &+= 1
        countLock.lock()
        producedFrames &+= 1
        countLock.unlock()

        onFrame?(EncodedFrame(data: jpeg,
                              width: displayWidth,
                              height: displayHeight,
                              sequence: sequence))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Capture stopped: \(error.localizedDescription)")
        Log.info("Usually this means the mirrored display was disconnected or switched to mirroring.")
        Log.info("Reconnect the virtual display and restart.")
    }

    // MARK: - Encode

    private func encodeJPEG(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return ciContext.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption:
                        quality.currentQuality])
    }
}

/// Adjusts JPEG quality to how well the client keeps up.
///
/// When the iPad 2 slows down or Wi-Fi gets congested, frames pile up on
/// the server. Lowering quality shrinks the frames and clears the backlog;
/// once things calm down quality climbs back gradually.
private final class QualityController {
    private let lock = NSLock()
    // At high frame rates the bottleneck is bandwidth, not encoding: the
    // iPad 2's single-antenna Wi-Fi carries 10-15 Mbps in practice. At
    // 60 fps that's ~25 KB per frame, reachable only at low quality. The
    // controller finds the quality that fits and holds it there.
    private var quality: Double = 0.40
    private var lastAdjustment = Date.distantPast

    private let minQuality = 0.15
    // The ceiling is set by the iPad's decode speed, not bandwidth. Over
    // USB the cable carries 40 Mbps easily, but at 75% quality frames get
    // big enough that decode goes from 20 ms to 80 ms and the device falls
    // behind. Measured: ~50% with 20 ms decode is the sweet spot.
    private let maxQuality = 0.52
    // At 60 fps a quarter second is 15 frames, enough for a backlog to
    // build. Sample more often and adjust in smaller steps.
    private let adjustInterval: TimeInterval = 0.1

    /// Queue depth that counts as congested. Depends on the link: the USB
    /// queue is deeper and holds a frame or two even when healthy, whereas
    /// on Wi-Fi two pending frames really means congestion.
    private var congestionThreshold = 2
    private var comfortThreshold = 0

    func configureForDeepQueue(_ deep: Bool) {
        lock.lock(); defer { lock.unlock() }
        congestionThreshold = deep ? 3 : 2
        comfortThreshold = deep ? 1 : 0
    }

    var currentQuality: Double {
        lock.lock(); defer { lock.unlock() }
        return quality
    }

    /// Manually set quality. `nil` means the controller is in charge.
    private var manualQuality: Double?

    func setManual(_ value: Double?) {
        lock.lock(); defer { lock.unlock() }
        manualQuality = value
        if let value { quality = value }
    }

    func reportBacklog(_ pending: Int) {
        lock.lock(); defer { lock.unlock() }

        // Pinned manually: the controller stays out of it.
        guard manualQuality == nil else { return }

        guard Date().timeIntervalSince(lastAdjustment) > adjustInterval else { return }
        lastAdjustment = Date()

        // Thresholds follow queue depth. On a deeper USB queue a fixed
        // `>= 2` threshold mistook normal operation for congestion and kept
        // pushing quality down, and `== 0` never happened, so it never
        // recovered.
        //
        // Steps are small because we sample ten times a second; big steps
        // make quality visibly pump up and down.
        if pending >= congestionThreshold {
            // Real backlog; step down.
            quality = max(minQuality, quality - 0.04)
        } else if pending <= comfortThreshold {
            // Plenty of headroom; creep back up. Rising slower than falling
            // avoids oscillating around the limit.
            quality = min(maxQuality, quality + 0.01)
        }
    }
}
