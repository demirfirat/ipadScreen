import Foundation
import SwiftUI
import ScreenCaptureKit
import AppKit

// MARK: - Arguments

struct Options {
    var port: UInt16 = 8765
    var fps: Int = 45
    var scale: Double = 1.0
    var displayIndex: Int?
    var listOnly = false
    var verbose = false
    var headless = false

    var scaleWasSet = false
    var fpsWasSet = false
    var useUSB = false
}

func parseArguments() -> Options {
    var opts = Options()
    var args = Array(CommandLine.arguments.dropFirst())

    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--port", "-p":
            if let v = args.first, let n = UInt16(v) { opts.port = n; args.removeFirst() }
        case "--fps", "-f":
            if let v = args.first, let n = Int(v) {
                opts.fps = max(1, min(60, n))
                opts.fpsWasSet = true
                args.removeFirst()
            }
        case "--scale", "-s":
            if let v = args.first, let n = Double(v) {
                opts.scale = max(0.25, min(1.0, n))
                opts.scaleWasSet = true
                args.removeFirst()
            }
        case "--display", "-d":
            if let v = args.first, let n = Int(v) { opts.displayIndex = n; args.removeFirst() }
        case "--list", "-l":
            opts.listOnly = true
        case "--usb", "-u":
            opts.useUSB = true
        case "--headless", "-H":
            opts.headless = true
        case "--verbose", "-v":
            opts.verbose = true
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            FileHandle.standardError.write(Data("Unknown option: \(arg)\n".utf8))
            printUsage()
            exit(1)
        }
    }
    return opts
}

func printUsage() {
    print("""
    ipadscreen — use an old iPad as a second display for your Mac

    USAGE
      ipadscreen [options]

    Without options it starts as a regular app with a menu bar icon.

    OPTIONS
      -H, --headless        run in the terminal, without UI
      -l, --list            list displays and exit
      -d, --display <n>     number of the display to mirror
      -p, --port <n>        server port (default: 8765)
      -f, --fps <n>         target frame rate, 1-60 (default: 45)
      -s, --scale <n>       capture scale, 0.25-1.0 (default: automatic)
      -u, --usb             connect over USB
      -v, --verbose         verbose logging
      -h, --help            show this help

    Options given here are saved to the settings and apply to later launches too.
    """)
}

// MARK: - App

@main
struct IPadScreenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // The window is the first scene because SwiftUI shows the first
        // scene at launch. With the menu bar extra first, the window never
        // opened and a first-time user was left with an inert Dock icon.
        Window("iPadScreen", id: "main") {
            MainWindow(state: delegate.state)
                .background(WindowOpenerCapture(delegate: delegate))
        }
        .defaultSize(width: 760, height: 480)

        MenuBarExtra {
            MenuBarPanel(state: delegate.state)
        } label: {
            MenuBarIcon(state: delegate.state)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar icon. A separate view so it can observe state: an `App` body
/// doesn't track `ObservableObject` changes on its own.
private struct MenuBarIcon: View {
    @ObservedObject var state: AppState

    var body: some View {
        Image(systemName: state.isRunning
              ? "rectangle.on.rectangle.fill"
              : "rectangle.on.rectangle")
    }
}

/// Hands the open-window action to the delegate.
///
/// `openWindow` is only available from the SwiftUI environment; when the
/// Dock icon is clicked and the window is closed, the delegate uses it to
/// reopen the window.
private struct WindowOpenerCapture: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .onAppear { delegate.openMainWindow = { openWindow(id: "main") } }
    }
}

/// App lifecycle and engine wiring.
///
/// The engine runs on `@MainActor` (capture callbacks write to the UI from
/// there), and the delegate lives on the same actor.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = Engine()
    private var attached = false

    /// UI state lives here, not in the window: the engine has to run
    /// whether or not the window is open. It used to start from the
    /// window's `.task`, so if the window didn't open, mirroring never
    /// started.
    let state = AppState()

    /// Opens the main window; set by SwiftUI once the window appears.
    var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = parseArguments()
        Log.verbose = options.verbose
        Settings.shared.applyCommandLine(options)

        // --list and --headless run without UI; close the window that
        // opens at launch.
        if options.listOnly || options.headless {
            NSApp.setActivationPolicy(.prohibited)
            NSApp.windows.forEach { $0.close() }
            if options.listOnly { runListAndExit() } else { runHeadless(options) }
            return
        }

        // Show in both the Dock and the menu bar: the menu bar for quick
        // access, the Dock for finding the app and bringing it forward.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        Task { await attach() }
    }

    /// Don't quit when the window closes: mirroring continues from the
    /// menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Brings the window back when the Dock icon is clicked.
    ///
    /// A closed SwiftUI window doesn't stay in `NSApp.windows`, so looking
    /// for it there found nothing. Reopen it with SwiftUI's own
    /// `openWindow` action instead.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMainWindow?()
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func attach() async {
        guard !attached else { return }
        attached = true

        engine.state = state

        state.onStartStop = { [weak self] shouldRun in
            Task { @MainActor in
                guard let self else { return }
                if shouldRun {
                    await self.startWithPermissionCheck()
                } else {
                    await self.engine.stop()
                }
            }
        }
        state.onSettingsChanged = { [weak self] in
            Task { @MainActor in
                await self?.engine.applyFrameRate()
                self?.engine.applyQuality()
            }
        }
        state.onRegenerateCode = { [weak self] in
            self?.engine.regeneratePairingCode()
        }
        state.onScaleChanged = { [weak self] in
            Task { @MainActor in await self?.engine.applyScale() }
        }
        state.onDisplayChanged = { [weak self] in
            Task { @MainActor in await self?.engine.applyScale() }
        }
        state.onConnectionModeChanged = { [weak self] in
            Task { @MainActor in await self?.engine.applyConnectionMode() }
        }

        engine.observeSleepWake()

        // Don't prompt at launch. If permission is already granted, start
        // right away; otherwise ask when the user presses Start.
        guard CGPreflightScreenCaptureAccess() else {
            state.statusText = "Screen Recording permission needed to start"
            return
        }
        await startEngine()
    }

    /// The Start button. Without permission it shows exactly one prompt:
    /// macOS's own the first time, ours after that.
    ///
    /// Showing both at once stacked two dialogs on top of each other. macOS
    /// only shows its prompt once per app; asking again does nothing, so
    /// from the second press on we show our own alert instead.
    private func startWithPermissionCheck() async {
        if CGPreflightScreenCaptureAccess() {
            await startEngine()
            return
        }

        let key = "screenCaptureRequested"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            CGRequestScreenCaptureAccess()
        } else {
            showPermissionAlert()
        }
    }

    private func startEngine() async {
        do {
            if state.availableDisplays.isEmpty {
                try await engine.loadDisplays()
            }
            try await engine.start()
        } catch {
            state.statusText = error.localizedDescription
            Log.error(error.localizedDescription)
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
            Turn on iPadScreen in System Settings › Privacy & Security › \
            Screen & System Audio Recording.

            After granting it, the app has to be relaunched; macOS only picks \
            up the permission then. The button below does that for you.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Relaunch")
        alert.addButton(withTitle: "Close")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            relaunch()
        default:
            break
        }
    }

    /// Quits and relaunches the app. After permission is granted this is
    /// the only way for macOS to pick it up.
    private func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        // Launch the new instance before quitting; `open -n` starts a
        // separate process without waiting for this one.
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Headless modes

    private func runListAndExit() {
        Task {
            guard ensureScreenRecordingPermission() else {
                print("\nNo Screen Recording permission. System Settings › Privacy & Security › Screen & System Audio Recording\n")
                exit(1)
            }
            let displays = (try? await ScreenCaptureEngine.availableDisplays()) ?? []
            print("\nDisplays:\n")
            for (i, d) in displays.enumerated() { print(describe(d, index: i + 1)) }
            print("")
            exit(0)
        }
    }

    private func runHeadless(_ options: Options) {
        Task { @MainActor in
            guard ensureScreenRecordingPermission() else {
                print("\nNo Screen Recording permission. Grant it and run again.\n")
                exit(1)
            }

            try? await engine.loadDisplays()

            if let index = options.displayIndex {
                let displays = (try? await ScreenCaptureEngine.availableDisplays()) ?? []
                guard index >= 1, index <= displays.count else {
                    print("No display \(index). See --list.")
                    exit(1)
                }
                Settings.shared.displayID = displays[index - 1].displayID
            }

            do {
                try await engine.start()
            } catch {
                print("Could not start: \(error.localizedDescription)")
                exit(1)
            }

            let ip = localIPAddress() ?? "<mac-ip>"
            let port = Settings.shared.port
            print("""

              Safari on the iPad: http://\(ip):\(port)
              Pairing code:       \(Settings.shared.pairingCode)
              Press Ctrl-C to stop

            """)

            signal(SIGINT) { _ in
                print("")
                exit(0)
            }
        }
    }
}
