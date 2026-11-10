import Foundation

/// An iPad model and the size of its screen.
///
/// Sizes are in points, which is what macOS lays a display out in: a Retina
/// iPad shows 1024×768 of content on its 2048×1536 panel, and the iPad 2
/// can't decode more pixels than that anyway.
struct IPadModel: Equatable {
    /// Apple's identifier, e.g. "iPad2,4".
    let identifier: String
    let name: String
    /// Landscape screen size, in points.
    let width: Int
    let height: Int

    /// Used when no iPad is attached and none has been seen before: the iPad 2
    /// this app was written for.
    static let fallback = IPadModel(identifier: "iPad2,1", name: "iPad 2",
                                    width: 1024, height: 768)

    /// Looks an identifier up. An unknown one still gets a usable size: the
    /// iPad 2's 4:3 panel, which is close to every iPad up to the 10.2-inch.
    init(identifier: String) {
        let id = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            self = .fallback
            return
        }
        guard let known = Self.models[id] else {
            self = IPadModel(identifier: id, name: "iPad", width: 1024, height: 768)
            return
        }
        self = IPadModel(identifier: id, name: known.name,
                         width: known.width, height: known.height)
    }

    private init(identifier: String, name: String, width: Int, height: Int) {
        self.identifier = identifier
        self.name = name
        self.width = width
        self.height = height
    }

    // MARK: - Detection

    /// Reads the model of a connected iPad with libimobiledevice's
    /// `ideviceinfo`. That sees a device over USB (or Wi-Fi sync, if it was
    /// paired for it); with no device, no tool, or an unexpected answer it
    /// returns nil and the caller keeps whatever it knew before.
    static func detect(timeout: TimeInterval = 2.5) -> IPadModel? {
        guard let tool = findTool("ideviceinfo") else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-k", "ProductType"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Without a device ideviceinfo can sit waiting; a start must not hang
        // on it.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !process.isRunning else {
            process.terminate()
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let identifier = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.hasPrefix("iPad") else { return nil }

        let model = IPadModel(identifier: identifier)
        Log.info("iPad detected: \(model.name) (\(identifier))")
        return model
    }

    /// Finds a program by name; Homebrew's path may not be on PATH for a GUI
    /// app.
    private static func findTool(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Table

    private struct Spec {
        let name: String
        let width: Int
        let height: Int
    }

    /// Identifiers from Apple's device list, grouped by panel.
    private static let table: [(ids: String, name: String, width: Int, height: Int)] = [
        ("iPad1,1", "iPad", 1024, 768),
        ("iPad2,1 iPad2,2 iPad2,3 iPad2,4", "iPad 2", 1024, 768),
        ("iPad2,5 iPad2,6 iPad2,7", "iPad mini", 1024, 768),
        ("iPad3,1 iPad3,2 iPad3,3", "iPad (3rd generation)", 1024, 768),
        ("iPad3,4 iPad3,5 iPad3,6", "iPad (4th generation)", 1024, 768),
        ("iPad4,1 iPad4,2 iPad4,3", "iPad Air", 1024, 768),
        ("iPad4,4 iPad4,5 iPad4,6", "iPad mini 2", 1024, 768),
        ("iPad4,7 iPad4,8 iPad4,9", "iPad mini 3", 1024, 768),
        ("iPad5,1 iPad5,2", "iPad mini 4", 1024, 768),
        ("iPad5,3 iPad5,4", "iPad Air 2", 1024, 768),
        ("iPad6,3 iPad6,4", "iPad Pro (9.7-inch)", 1024, 768),
        ("iPad6,11 iPad6,12", "iPad (5th generation)", 1024, 768),
        ("iPad7,5 iPad7,6", "iPad (6th generation)", 1024, 768),
        ("iPad11,1 iPad11,2", "iPad mini 5", 1024, 768),
        ("iPad6,7 iPad6,8 iPad7,1 iPad7,2", "iPad Pro (12.9-inch)", 1366, 1024),
        ("iPad8,5 iPad8,6 iPad8,7 iPad8,8", "iPad Pro (12.9-inch, 3rd gen)", 1366, 1024),
        ("iPad8,11 iPad8,12", "iPad Pro (12.9-inch, 4th gen)", 1366, 1024),
        ("iPad13,8 iPad13,9 iPad13,10 iPad13,11", "iPad Pro (12.9-inch, 5th gen)", 1366, 1024),
        ("iPad14,5 iPad14,6", "iPad Pro (12.9-inch, 6th gen)", 1366, 1024),
        ("iPad14,10 iPad14,11", "iPad Air (13-inch, M2)", 1366, 1024),
        ("iPad16,5 iPad16,6", "iPad Pro (13-inch, M4)", 1376, 1032),
        ("iPad7,3 iPad7,4", "iPad Pro (10.5-inch)", 1112, 834),
        ("iPad11,3 iPad11,4", "iPad Air (3rd generation)", 1112, 834),
        ("iPad8,1 iPad8,2 iPad8,3 iPad8,4", "iPad Pro (11-inch)", 1194, 834),
        ("iPad8,9 iPad8,10", "iPad Pro (11-inch, 2nd gen)", 1194, 834),
        ("iPad13,4 iPad13,5 iPad13,6 iPad13,7", "iPad Pro (11-inch, 3rd gen)", 1194, 834),
        ("iPad14,3 iPad14,4", "iPad Pro (11-inch, 4th gen)", 1194, 834),
        ("iPad16,3 iPad16,4", "iPad Pro (11-inch, M4)", 1210, 834),
        ("iPad7,11 iPad7,12", "iPad (7th generation)", 1080, 810),
        ("iPad11,6 iPad11,7", "iPad (8th generation)", 1080, 810),
        ("iPad12,1 iPad12,2", "iPad (9th generation)", 1080, 810),
        ("iPad13,1 iPad13,2", "iPad Air (4th generation)", 1180, 820),
        ("iPad13,16 iPad13,17", "iPad Air (5th generation)", 1180, 820),
        ("iPad13,18 iPad13,19", "iPad (10th generation)", 1180, 820),
        ("iPad14,8 iPad14,9", "iPad Air (11-inch, M2)", 1180, 820),
        ("iPad14,1 iPad14,2", "iPad mini 6", 1133, 744),
        ("iPad16,1 iPad16,2", "iPad mini (A17 Pro)", 1133, 744),
    ]

    private static let models: [String: Spec] = {
        var map: [String: Spec] = [:]
        for entry in table {
            let spec = Spec(name: entry.name, width: entry.width, height: entry.height)
            for id in entry.ids.split(separator: " ") {
                map[String(id)] = spec
            }
        }
        return map
    }()
}
