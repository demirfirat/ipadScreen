import Foundation
import CoreGraphics
import CGVirtualDisplayShim

/// Which side of the Mac's own screen the virtual display sits on.
///
/// The window server picks a side for a new display, and it isn't always the
/// one you want, so the app places it explicitly and lets the user choose.
enum VirtualDisplaySide: String, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

/// A virtual (headless) display created and owned by this app.
///
/// ScreenCaptureKit can only capture a display that exists, so making an iPad
/// an extra desktop needs a second display before anything can be streamed.
/// macOS has no public API to create one, so this uses the private
/// CoreGraphics classes described in `CGVirtualDisplayShim.h`.
///
/// The screen lives exactly as long as this object: release it (or quit the
/// app) and macOS removes it from the arrangement.
final class VirtualDisplay {

    /// Shown in System Settings › Displays and in the app's display picker.
    static let defaultName = "iPadScreen"

    /// Vendor and product stay the same; the serial number is fresh for every
    /// display that gets created.
    ///
    /// Reusing a serial is not reliable. The window server keeps a record of a
    /// display after it has gone, and creating one with the same identity can
    /// then be refused outright (seen on macOS 27 as a bare refused
    /// initializer). A new serial sidesteps that, and costs nothing: the
    /// position is set explicitly by `place(beside:)` rather than
    /// remembered by identity.
    private enum Identity {
        static let vendorID: UInt32 = 0x1D5C
        static let productID: UInt32 = 0x0002
    }

    /// The queue the display's window-server connection runs on. A dedicated
    /// queue, not the main one: creating and tearing a display down then
    /// doesn't depend on the main run loop being serviced.
    private let queue = DispatchQueue(label: "ipadscreen.virtualdisplay")

    private var display: CGVirtualDisplay?

    /// CoreGraphics ID of the created display; 0 when there isn't one.
    private(set) var displayID: CGDirectDisplayID = 0
    private(set) var width = 0
    private(set) var height = 0

    var isActive: Bool { display != nil }

    /// Whether this macOS still ships the private classes. Apple can remove
    /// them in any release, so the app checks instead of assuming.
    static var isSupported: Bool {
        NSClassFromString("CGVirtualDisplayDescriptor") != nil
    }

    /// Creates a `width`×`height` display and returns its display ID.
    /// Replaces any display this object already owns.
    @discardableResult
    func create(width widthIn: Int, height heightIn: Int, side: VirtualDisplaySide,
                name: String = VirtualDisplay.defaultName,
                refreshRate: Double = 60) -> CGDirectDisplayID? {
        destroy()

        guard Self.isSupported else {
            Log.error("This macOS has no virtual display support (CGVirtualDisplay)")
            return nil
        }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(widthIn)
        descriptor.maxPixelsHigh = UInt32(heightIn)
        // Roughly the 163 ppi of an iPad panel. macOS only uses this to size
        // the screen in the arrangement, but a wrong figure makes the
        // display look enormous or tiny next to real monitors.
        let ppi = 163.0
        descriptor.sizeInMillimeters = CGSize(width: Double(widthIn) / ppi * 25.4,
                                              height: Double(heightIn) / ppi * 25.4)
        descriptor.vendorID = Identity.vendorID
        descriptor.productID = Identity.productID
        // sRGB primaries; without them some tools report an odd color space.
        descriptor.whitePoint = CGPoint(x: 0.3125, y: 0.3291)
        descriptor.redPrimary = CGPoint(x: 0.64, y: 0.33)
        descriptor.greenPrimary = CGPoint(x: 0.30, y: 0.60)
        descriptor.bluePrimary = CGPoint(x: 0.15, y: 0.06)
        descriptor.queue = queue

        // Creation is occasionally refused outright, apparently while the
        // window server is still tearing down an earlier display, so retry a
        // couple of times with a fresh identity before giving up.
        var created: CGVirtualDisplay?
        for attempt in 1...3 {
            descriptor.serialNum = UInt32.random(in: 1...UInt32.max)
            if let display = CGVirtualDisplay(descriptor: descriptor) {
                created = display
                break
            }
            Log.debug("Virtual display refused (attempt \(attempt) of 3); retrying")
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard let display = created else {
            Log.error("CoreGraphics refused to create a virtual display")
            return nil
        }

        let mode = CGVirtualDisplayMode(width: UInt32(widthIn),
                                        height: UInt32(heightIn),
                                        refreshRate: refreshRate)
        let settings = CGVirtualDisplaySettings()
        settings.modes = [mode]
        settings.hiDPI = 0

        // `applySettings:` imports as `apply(_:)`: Swift drops the noun the
        // method is named after.
        guard display.apply(settings) else {
            Log.error("The virtual display rejected its \(widthIn)×\(heightIn) mode")
            return nil
        }

        self.display = display
        displayID = display.displayID
        width = widthIn
        height = heightIn
        place(beside: side)
        return displayID
    }

    /// Puts the display beside the main display, top edges aligned, on the
    /// side that was asked for.
    ///
    /// A new display otherwise lands wherever the window server decides, which
    /// on this Mac was the left no matter what. Called when the display is
    /// created and again when the setting changes, so dragging it somewhere
    /// else in between sticks.
    func place(beside side: VirtualDisplaySide) {
        Self.place(displayID: displayID, width: width, beside: side)
    }

    /// Moves any display to a side of the main one.
    ///
    /// Takes a display ID rather than an object because a display this app
    /// created in an earlier run (and left behind when it quit badly) is still
    /// ours to move, but no `CGVirtualDisplay` object exists for it here.
    static func place(displayID: CGDirectDisplayID, width displayWidth: Int,
                      beside side: VirtualDisplaySide) {
        guard displayID != 0 else { return }

        // Origins are relative to the main display's top-left corner, so its
        // edges are where this display has to start or end.
        let main = CGDisplayBounds(CGMainDisplayID())
        let x = side == .left ? main.minX - CGFloat(displayWidth) : main.maxX
        let y = main.minY

        // A new display isn't in the arrangement until the window server has
        // brought it online, and an origin set before then is dropped, leaving
        // macOS's own choice (the left). So wait for it and check where the
        // display actually ended up, instead of trusting the return code.
        let deadline = Date().addingTimeInterval(1.5)
        while true {
            if CGDisplayIsOnline(displayID) != 0 {
                var configuration: CGDisplayConfigRef?
                if CGBeginDisplayConfiguration(&configuration) == .success, let configuration {
                    CGConfigureDisplayOrigin(configuration, displayID, Int32(x), Int32(y))
                    CGCompleteDisplayConfiguration(configuration, .forSession)
                }
                let actual = CGDisplayBounds(displayID).origin
                if abs(actual.x - x) <= 1, abs(actual.y - y) <= 1 {
                    Log.debug("Display \(displayID) placed at \(actual), \(side.title.lowercased()) of the main screen")
                    return
                }
            }
            guard Date() < deadline else {
                Log.error("Could not move display \(displayID) beside the main screen")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Releases the display; macOS takes it out of the arrangement.
    func destroy() {
        display = nil
        displayID = 0
        width = 0
        height = 0
    }
}
