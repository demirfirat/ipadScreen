import Foundation
import SwiftUI
import ScreenCaptureKit

/// Live state observed by the UI.
///
/// The capture and server layers write here and SwiftUI views read from it.
/// Every update is hopped onto the main thread because frames arrive on
/// background queues.
@MainActor
final class AppState: ObservableObject {

    enum Connection: String {
        case usb = "USB"
        case wifi = "Wi-Fi"
    }

    // Status
    @Published var isRunning = false
    @Published var clientCount = 0
    @Published var connection: Connection = .wifi
    /// Why something is wrong, if anything; empty when all is well.
    @Published var statusText = ""

    /// Code a device enters to receive the stream over Wi-Fi.
    @Published var pairingCode = Settings.shared.pairingCode

    // Live measurements
    @Published var currentFPS: Double = 0
    @Published var currentQuality: Double = 0
    @Published var megabitsPerSecond: Double = 0
    @Published var frameSize: CGSize = .zero

    /// Frame rate over the last 60 seconds; drives the chart in the UI.
    @Published var fpsHistory: [Double] = []

    // Settings (changed from the UI)
    @Published var targetFPS: Int {
        didSet { Settings.shared.fps = targetFPS; onSettingsChanged?() }
    }
    @Published var useUSB: Bool {
        didSet { Settings.shared.useUSB = useUSB; onConnectionModeChanged?() }
    }
    @Published var autoQuality: Bool {
        didSet { Settings.shared.autoQuality = autoQuality; onSettingsChanged?() }
    }
    @Published var manualQuality: Double {
        didSet { Settings.shared.quality = manualQuality; onSettingsChanged?() }
    }
    @Published var scale: Double {
        didSet { Settings.shared.scale = scale; onScaleChanged?() }
    }

    // Display selection
    @Published var availableDisplays: [DisplayInfo] = []
    @Published var selectedDisplayID: UInt32 = 0 {
        didSet { Settings.shared.displayID = selectedDisplayID; onDisplayChanged?() }
    }

    struct DisplayInfo: Identifiable, Hashable {
        let id: UInt32
        let name: String
        let width: Int
        let height: Int
        let isVirtual: Bool

        var label: String { "\(name) — \(width)×\(height)" }
    }

    // Actions; wired up by AppDelegate.
    var onSettingsChanged: (() -> Void)?
    var onScaleChanged: (() -> Void)?
    var onDisplayChanged: (() -> Void)?
    var onConnectionModeChanged: (() -> Void)?
    var onStartStop: ((Bool) -> Void)?
    var onRegenerateCode: (() -> Void)?

    init() {
        let s = Settings.shared
        targetFPS = s.fps
        useUSB = s.useUSB
        autoQuality = s.autoQuality
        manualQuality = s.quality
        scale = s.scale
        selectedDisplayID = s.displayID

        // Show a meaningful value before capture starts; otherwise the
        // panel reads "0% quality" and looks broken.
        currentQuality = s.quality
    }

    /// Records a measurement sample; the chart shows the last 60.
    func recordSample(fps: Double, quality: Double, mbps: Double) {
        currentFPS = fps
        currentQuality = quality
        megabitsPerSecond = mbps

        fpsHistory.append(fps)
        if fpsHistory.count > 60 { fpsHistory.removeFirst() }
    }
}
