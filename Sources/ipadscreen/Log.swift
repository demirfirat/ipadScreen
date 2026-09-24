import Foundation

enum Log {
    /// Enabled with `--verbose`; per-frame noise is hidden otherwise.
    nonisolated(unsafe) static var verbose = false

    private static let lock = NSLock()

    private static func write(_ symbol: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        let time = timeFormatter.string(from: Date())
        print("\(time) \(symbol) \(message)")
        fflush(stdout)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func info(_ message: String) { write("•", message) }
    static func error(_ message: String) { write("✗", message) }
    static func success(_ message: String) { write("✓", message) }
    static func debug(_ message: String) {
        guard verbose else { return }
        write("·", message)
    }
}
