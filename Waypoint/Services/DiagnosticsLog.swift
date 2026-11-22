import Darwin
import Foundation
import os

/// Persistent, timestamped diagnostics for the native bridge and the cellular
/// handoff. Safe to call from any queue; disk writes happen off the caller's
/// thread so logging cannot add latency to a location write.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    private static let subsystem = "app.waypoint.ios"
    private static let maxFileBytes = 512 * 1024
    private static let maxMemoryEntries = 2_000

    private let logger = Logger(subsystem: DiagnosticsLog.subsystem, category: "diagnostics")
    private let lock = NSLock()
    private let fileQueue = DispatchQueue(label: "app.waypoint.diagnostics", qos: .utility)
    private let formatter: ISO8601DateFormatter
    private let fileURL: URL

    private var memoryEntries: [String] = []
    private var fileHandle: FileHandle?
    private var fileBytes = 0

    private init() {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent("Waypoint", isDirectory: true)
        fileURL = directory.appendingPathComponent("diagnostics.log")

        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileQueue.sync { self.openFile() }

        record("lifecycle", "diagnostics started", metadata: Self.environmentMetadata())
    }

    deinit {
        fileQueue.sync {
            try? self.fileHandle?.close()
            self.fileHandle = nil
        }
    }

    var fileLocation: URL { fileURL }

    var summary: String {
        fileQueue.sync {
            lock.lock()
            let count = memoryEntries.count
            lock.unlock()
            return "\(count) entries, \(max(1, fileBytes / 1024)) KB"
        }
    }

    func record(
        _ category: String,
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        lock.lock()
        let line = formatLine(category: category, message: message, metadata: metadata)
        memoryEntries.append(line)
        if memoryEntries.count > Self.maxMemoryEntries {
            memoryEntries.removeFirst(memoryEntries.count - Self.maxMemoryEntries)
        }
        lock.unlock()

        logger.info("\(line, privacy: .public)")
        fileQueue.async { self.appendToFile(line) }
    }

    func exportText() -> String {
        fileQueue.sync {
            if fileHandle == nil { openFile() }
            try? fileHandle?.synchronize()

            if let text = try? String(contentsOf: fileURL, encoding: .utf8),
               !text.isEmpty {
                return text
            }

            lock.lock()
            defer { lock.unlock() }
            guard !memoryEntries.isEmpty else { return "" }
            return memoryEntries.joined(separator: "\n") + "\n"
        }
    }

    func clear() {
        fileQueue.sync {
            try? fileHandle?.close()
            fileHandle = nil
            fileBytes = 0
            try? FileManager.default.removeItem(at: fileURL)
            openFile()
        }

        lock.lock()
        memoryEntries.removeAll()
        lock.unlock()

        record("lifecycle", "diagnostics cleared")
    }

    static func elapsedMilliseconds(since start: Date) -> String {
        String(Int(Date().timeIntervalSince(start) * 1_000))
    }

    private func formatLine(
        category: String,
        message: String,
        metadata: [String: String]
    ) -> String {
        var line = "\(formatter.string(from: Date())) [\(category)] \(sanitize(message))"
        if !metadata.isEmpty {
            let pairs = metadata.keys.sorted().map { key in
                "\(key)=\"\(sanitize(metadata[key] ?? ""))\""
            }
            line += " " + pairs.joined(separator: " ")
        }
        return line
    }

    private func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func appendToFile(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if fileHandle == nil { openFile() }

        if fileBytes + data.count > Self.maxFileBytes {
            rewriteFileFromMemory()
        }

        do {
            try fileHandle?.write(contentsOf: data)
            fileBytes += data.count
        } catch {
            logger.error("diagnostics write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rewriteFileFromMemory() {
        lock.lock()
        let recent = memoryEntries.joined(separator: "\n") + "\n"
        lock.unlock()

        try? fileHandle?.close()
        fileHandle = nil
        try? recent.write(to: fileURL, atomically: true, encoding: .utf8)
        openFile()
    }

    private func openFile() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: fileURL.path) {
            _ = fileManager.createFile(atPath: fileURL.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: fileURL)
        try? fileHandle?.seekToEnd()
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
        fileBytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func environmentMetadata() -> [String: String] {
        let info = Bundle.main.infoDictionary ?? [:]
        let process = ProcessInfo.processInfo
        return [
            "app": "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))",
            "device": machineIdentifier(),
            "ios": process.operatingSystemVersionString,
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier,
            "low_power": String(process.isLowPowerModeEnabled),
            "thermal": thermalStateName(process.thermalState)
        ]
    }

    private static func machineIdentifier() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    private static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
