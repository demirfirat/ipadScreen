import Foundation
import ScreenCaptureKit
import AppKit

/// The display's name as macOS shows it.
func displayName(_ display: SCDisplay) -> String {
    let screen = NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
            == display.displayID
    }
    return screen?.localizedName ?? "Display \(display.displayID)"
}

/// Virtual displays from BetterDisplay and similar tools carry "virtual"
/// (or the localized "sanal" on Turkish systems) in their name. That's more
/// reliable than looking at size: a HiDPI virtual display can have more
/// pixels than a physical monitor.
func isVirtualDisplay(_ display: SCDisplay) -> Bool {
    let name = displayName(display).lowercased()
    return name.contains("sanal") || name.contains("virtual") || name.contains("dummy")
}

/// Sending a HiDPI display to the iPad as-is is wasted work: there's no
/// point encoding 2048x1536 for a 1024x768 panel. When no scale is given we
/// drop to the logical (backing-scale) size, i.e. half.
func autoScale(for display: SCDisplay) -> Double? {
    let screen = NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
            == display.displayID
    }
    guard let factor = screen?.backingScaleFactor, factor > 1 else { return nil }
    return 1.0 / Double(factor)
}

func describe(_ display: SCDisplay, index: Int) -> String {
    let name = displayName(display)
    let marker = isVirtualDisplay(display) ? "  ← virtual" : ""
    return String(format: "  [%d] %-28s %4d x %-4d%@", index, (name as NSString).utf8String!,
                  display.width, display.height, marker)
}

/// IP address of the wireless interface, i.e. what the iPad connects to.
func localIPAddress() -> String? {
    var address: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    // en0 is usually Wi-Fi; otherwise fall back to any other IPv4 interface.
    var fallback: String?
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(ptr.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        guard ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(ptr.pointee.ifa_addr,
                          socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                          &host, socklen_t(host.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { continue }

        let name = String(cString: ptr.pointee.ifa_name)
        let ip = String(cString: host)
        if name == "en0" { address = ip; break }
        if fallback == nil { fallback = ip }
    }
    return address ?? fallback
}

/// Finds a program by name. Homebrew's path may not be on PATH for GUI apps.
func findExecutable(_ name: String) -> String? {
    let candidates = [
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
        "/usr/bin/\(name)",
    ]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    return nil
}

/// Folder holding the web viewer page.
func resolveWebRoot() -> URL {
    let fm = FileManager.default
    func hasViewer(_ url: URL) -> Bool {
        fm.fileExists(atPath: url.appendingPathComponent("viewer.html").path)
    }

    // 1. Inside the .app: Contents/Resources/web
    if let resources = Bundle.main.resourceURL {
        let web = resources.appendingPathComponent("web")
        if hasViewer(web) { return web }
    }

    // 2. Next to the binary (manual installs).
    let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
        .deletingLastPathComponent()
    let beside = exeDir.appendingPathComponent("web")
    if hasViewer(beside) { return beside }

    // 3. Development: `swift run` from the repo root. We deliberately
    // avoid the compile-time path (`#filePath`) here; it got embedded in
    // the binary along with the user name.
    return URL(fileURLWithPath: fm.currentDirectoryPath)
        .appendingPathComponent("Sources/ipadscreen/web")
}

/// Without Screen Recording permission ScreenCaptureKit returns an empty list.
func ensureScreenRecordingPermission() -> Bool {
    if CGPreflightScreenCaptureAccess() { return true }
    CGRequestScreenCaptureAccess()
    return false
}
