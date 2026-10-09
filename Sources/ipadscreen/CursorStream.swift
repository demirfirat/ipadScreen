import AppKit

/// Sends the mouse cursor to the iPad as small control messages instead of
/// drawing it into the video.
///
/// With the cursor in the picture, every mouse movement is a new frame to
/// capture, encode, send and decode. As a separate layer on the iPad it
/// costs a few bytes and stays smooth even while the video is busy.
///
///     cursor=<x>,<y>                          position, 0-10000 across the
///                                             mirrored display; -1,-1 when
///                                             the pointer is elsewhere
///     cursor=off                              overlay stopped; draw nothing
///     cursorimg=<hx>,<hy>,<w>,<h>,<base64>   PNG, sized in stream pixels,
///                                             with its hotspot
///
/// Messages are ASCII and stay under the iPad's 4096-byte control limit, so
/// an iPad app without cursor support just ignores them.
final class CursorStream {

    private let displayID: CGDirectDisplayID
    private let frameWidth: Int
    private let send: (String) -> Void
    /// Whether every viewer can show the overlay. When a browser is
    /// watching too, the cursor has to stay in the video.
    private let isActive: () -> Bool
    /// Called when the overlay turns on or off, so the capture can stop or
    /// start drawing the cursor into the video.
    private let onActiveChanged: (Bool) -> Void

    private let queue = DispatchQueue(label: "ipadscreen.cursor", qos: .userInteractive)
    private var positionTimer: DispatchSourceTimer?
    private var imageTimer: Timer?

    // Touched only on `queue`.
    private var lastX = Int.min
    private var lastY = Int.min
    private var wasActive = false

    // Touched only on the main thread.
    private var imageMessage: String?
    private var imageHash = 0
    private var lastImageSend = Date.distantPast

    /// Largest message sent; the iPad drops the connection above 4096.
    private let maxMessageBytes = 3500
    private let maxImagePixels = 96

    init(displayID: CGDirectDisplayID, frameWidth: Int,
         isActive: @escaping () -> Bool, onActiveChanged: @escaping (Bool) -> Void,
         send: @escaping (String) -> Void) {
        self.displayID = displayID
        self.frameWidth = frameWidth
        self.isActive = isActive
        self.onActiveChanged = onActiveChanged
        self.send = send
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.pollPosition() }
        timer.resume()
        positionTimer = timer

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.imageTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.pollImage()
            }
        }
    }

    func stop() {
        positionTimer?.cancel()
        positionTimer = nil
        DispatchQueue.main.async { [weak self] in
            self?.imageTimer?.invalidate()
            self?.imageTimer = nil
        }
        queue.async { [self] in
            if wasActive {
                send("cursor=off")
                onActiveChanged(false)
            }
            wasActive = false
        }
    }

    // MARK: - Position

    private func pollPosition() {
        let active = isActive()
        if active != wasActive {
            wasActive = active
            onActiveChanged(active)
            if active {
                lastX = Int.min   // force a position
                DispatchQueue.main.async { [weak self] in self?.imageHash = 0 }
            } else {
                send("cursor=off")
            }
        }
        guard active, let location = CGEvent(source: nil)?.location else { return }

        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let nx = (location.x - bounds.minX) / bounds.width
        let ny = (location.y - bounds.minY) / bounds.height

        var x = -1, y = -1
        if (0...1).contains(nx), (0...1).contains(ny) {
            x = Int((nx * 10000).rounded())
            y = Int((ny * 10000).rounded())
        }
        guard x != lastX || y != lastY else { return }
        lastX = x
        lastY = y
        send("cursor=\(x),\(y)")
    }

    // MARK: - Image

    /// The cursor shape changes now and then (arrow, text bar, hand). It's
    /// checked ten times a second and resent every two seconds, so an iPad
    /// that connects later, or missed one, catches up.
    private func pollImage() {
        guard isActive() else { return }
        if let message = renderCursor() {
            let changed = message.hashValue != imageHash
            if changed || Date().timeIntervalSince(lastImageSend) > 2 {
                imageHash = message.hashValue
                imageMessage = message
                lastImageSend = Date()
                send(message)
            }
        }
    }

    private func renderCursor() -> String? {
        guard let cursor = NSCursor.currentSystem else { return imageMessage }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0 else { return imageMessage }

        // Points on the Mac → pixels of the stream.
        let k = Double(frameWidth) / Double(bounds.width)
        let image = cursor.image
        let w = max(1, Int((Double(image.size.width) * k).rounded()))
        let h = max(1, Int((Double(image.size.height) * k).rounded()))
        guard w <= maxImagePixels, h <= maxImagePixels,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return imageMessage }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h),
                   from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { return imageMessage }
        let hx = Int((Double(cursor.hotSpot.x) * k).rounded())
        let hy = Int((Double(cursor.hotSpot.y) * k).rounded())
        let message = "cursorimg=\(hx),\(hy),\(w),\(h),\(png.base64EncodedString())"
        // Too big for the control limit: keep the previous shape.
        return message.utf8.count <= maxMessageBytes ? message : imageMessage
    }
}
