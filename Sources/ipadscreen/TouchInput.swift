import Foundation
import CoreGraphics
import ApplicationServices

/// Turns the iPad's touches into mouse events on the mirrored display.
///
/// The iPad sends the same normalized coordinates as the cursor messages
/// (0-10000 across the picture), so touching the picture puts the Mac's
/// pointer under the finger. A touch is a left click: down, any number of
/// drags, up. It uses the ordinary control channel, so it works over USB and
/// Wi-Fi without a protocol change.
///
/// Posting events needs Accessibility permission. Without it macOS drops
/// them without a word, so the first touch asks for it once, and says so in
/// the log, rather than leaving someone tapping a screen that ignores them.
final class TouchInput {

    private enum Phase: String {
        case down, move, up
    }

    private let displayID: CGDirectDisplayID
    /// Touches arrive on the network queue and the watchdog runs on a timer;
    /// one serial queue keeps the button state from being raced.
    private let queue = DispatchQueue(label: "ipadscreen.touch", qos: .userInteractive)

    // Touched only on `queue`.
    private var isDown = false
    private var lastMessage = Date.distantPast
    private var watchdog: DispatchSourceTimer?
    private var askedForAccess = false

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 0.5, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.releaseIfStale() }
        timer.resume()
        watchdog = timer
    }

    func stop() {
        queue.sync {
            watchdog?.cancel()
            watchdog = nil
            release(at: nil)
        }
    }

    /// "touch=down,5000,5000", "touch=move,…", "touch=up,…".
    func handle(_ message: String) {
        queue.async { [weak self] in self?.apply(message) }
    }

    private func apply(_ message: String) {
        guard message.hasPrefix("touch=") else { return }
        let parts = message.dropFirst(6).split(separator: ",")
        guard parts.count == 3,
              let phase = Phase(rawValue: String(parts[0])),
              let nx = Int(parts[1]), let ny = Int(parts[2]) else { return }

        lastMessage = Date()
        let point = location(nx: nx, ny: ny)

        switch phase {
        case .down:
            // A down we never saw the end of (the app was killed mid-drag)
            // would leave the button stuck down.
            if isDown { release(at: point) }
            post(.leftMouseDown, at: point)
            isDown = true
        case .move:
            guard isDown else { return }
            post(.leftMouseDragged, at: point)
        case .up:
            guard isDown else { return }
            post(.leftMouseUp, at: point)
            isDown = false
        }
    }

    /// The picture is mapped onto the display, so the normalized position is
    /// the same fraction of the display's bounds.
    private func location(nx: Int, ny: Int) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        let fx = CGFloat(min(max(nx, 0), 10000)) / 10000.0
        let fy = CGFloat(min(max(ny, 0), 10000)) / 10000.0
        return CGPoint(x: bounds.minX + fx * bounds.width,
                       y: bounds.minY + fy * bounds.height)
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        guard hasAccess() else { return }
        guard let event = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                                  mouseType: type,
                                  mouseCursorPosition: point,
                                  mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
    }

    /// Lifts the button if the iPad stops talking mid-drag (connection lost,
    /// app quit, cable pulled). A click that never ends would make the whole
    /// Mac feel broken.
    private func releaseIfStale() {
        guard isDown, Date().timeIntervalSince(lastMessage) > 1.5 else { return }
        release(at: nil)
    }

    private func release(at point: CGPoint?) {
        guard isDown else { return }
        let bounds = CGDisplayBounds(displayID)
        let where_ = point ?? CGEvent(source: nil)?.location
            ?? CGPoint(x: bounds.midX, y: bounds.midY)
        post(.leftMouseUp, at: where_)
        isDown = false
    }

    /// Asks once, the first time a touch needs it. The prompt is the only
    /// thing that can grant this; a rebuild also drops it again unless the
    /// app is signed (`./setup-signing.sh`).
    private func hasAccess() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !askedForAccess {
            askedForAccess = true
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let options = [key: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            Log.error("Touches need Accessibility permission for iPadScreen; allow it in "
                      + "System Settings → Privacy & Security → Accessibility")
        }
        return false
    }
}
