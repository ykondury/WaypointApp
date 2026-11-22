import Combine
import Foundation
import Network

enum PhysicalConnectionKind: Equatable, Sendable {
    case unknown
    case offline
    case cellular
    case wifi
}

/// Observes a real cellular path independently of LocalDevVPN. The handoff
/// must not report success merely because its retained local socket still works
/// in Airplane Mode or because Wi-Fi reconnected behind the scenes.
final class CellularPathMonitor: ObservableObject, @unchecked Sendable {
    static let shared = CellularPathMonitor()

    @Published private(set) var activeConnection: PhysicalConnectionKind = .unknown

    private let cellularMonitor = NWPathMonitor(requiredInterfaceType: .cellular)
    private let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let cellularQueue = DispatchQueue(label: "app.waypoint.cellular-path")
    private let wifiQueue = DispatchQueue(label: "app.waypoint.wifi-path")
    private let lock = NSLock()
    private var hasCellularSample = false
    private var hasWiFiSample = false
    private var cellularIsSatisfied = false
    private var wifiIsSatisfied = false
    private var cellularOnlySince: Date?
    private var offlineSince: Date?

    func isCellularOnly(stableFor duration: TimeInterval = 0) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard hasCellularSample,
              hasWiFiSample,
              cellularIsSatisfied,
              !wifiIsSatisfied,
              let cellularOnlySince else {
            return false
        }

        return Date().timeIntervalSince(cellularOnlySince) >= duration
    }

    func isOffline(stableFor duration: TimeInterval = 0) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard hasCellularSample,
              hasWiFiSample,
              !cellularIsSatisfied,
              !wifiIsSatisfied,
              let offlineSince else {
            return false
        }

        return Date().timeIntervalSince(offlineSince) >= duration
    }

    /// Compact snapshot for handoff diagnostics. Safe to read from any queue.
    var diagnosticSummary: String {
        lock.lock()
        defer { lock.unlock() }

        let cellularOnly = cellularOnlySince.map {
            String(format: "%.1f", Date().timeIntervalSince($0))
        } ?? "-"
        let offline = offlineSince.map {
            String(format: "%.1f", Date().timeIntervalSince($0))
        } ?? "-"
        return "active=\(Self.name(currentConnectionLocked())) cellular=\(cellularIsSatisfied) wifi=\(wifiIsSatisfied) cellular_only_s=\(cellularOnly) offline_s=\(offline)"
    }

    private init() {
        cellularMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.update(
                cellular: path.status == .satisfied,
                path: path,
                source: "cellular"
            )
        }
        wifiMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.update(
                wifi: path.status == .satisfied,
                path: path,
                source: "wifi"
            )
        }
        cellularMonitor.start(queue: cellularQueue)
        wifiMonitor.start(queue: wifiQueue)
    }

    private func update(
        cellular: Bool? = nil,
        wifi: Bool? = nil,
        path: NWPath? = nil,
        source: String
    ) {
        lock.lock()

        let previousActive = currentConnectionLocked()
        let previousCellular = cellularIsSatisfied
        let previousWiFi = wifiIsSatisfied

        if let cellular {
            hasCellularSample = true
            cellularIsSatisfied = cellular
        }
        if let wifi {
            hasWiFiSample = true
            wifiIsSatisfied = wifi
        }

        if hasCellularSample &&
            hasWiFiSample &&
            cellularIsSatisfied &&
            !wifiIsSatisfied {
            if cellularOnlySince == nil {
                cellularOnlySince = Date()
            }
        } else {
            cellularOnlySince = nil
        }

        if hasCellularSample &&
            hasWiFiSample &&
            !cellularIsSatisfied &&
            !wifiIsSatisfied {
            if offlineSince == nil {
                offlineSince = Date()
            }
        } else {
            offlineSince = nil
        }

        let active = currentConnectionLocked()
        let cellularOnly = cellularOnlySince.map {
            String(format: "%.1f", Date().timeIntervalSince($0))
        } ?? "-"
        let offline = offlineSince.map {
            String(format: "%.1f", Date().timeIntervalSince($0))
        } ?? "-"
        let changed = active != previousActive ||
            cellularIsSatisfied != previousCellular ||
            wifiIsSatisfied != previousWiFi
        let cellularNow = cellularIsSatisfied
        let wifiNow = wifiIsSatisfied
        lock.unlock()

        if changed {
            var metadata = pathMetadata(path)
            metadata["source"] = source
            metadata["active"] = Self.name(active)
            metadata["cellular"] = String(cellularNow)
            metadata["wifi"] = String(wifiNow)
            metadata["cellular_only_s"] = cellularOnly
            metadata["offline_s"] = offline
            DiagnosticsLog.shared.record("path", "transition", metadata: metadata)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let connection = self.currentConnection()
            if self.activeConnection != connection {
                self.activeConnection = connection
            }
        }
    }

    private func currentConnection() -> PhysicalConnectionKind {
        lock.lock()
        defer { lock.unlock() }
        return currentConnectionLocked()
    }

    private func currentConnectionLocked() -> PhysicalConnectionKind {
        guard hasCellularSample, hasWiFiSample else { return .unknown }
        if wifiIsSatisfied { return .wifi }
        if cellularIsSatisfied { return .cellular }
        return .offline
    }

    private func pathMetadata(_ path: NWPath?) -> [String: String] {
        guard let path else { return [:] }
        return [
            "path_status": path.status == .satisfied ? "satisfied" : "unsatisfied",
            "interfaces": path.availableInterfaces.map { "\($0.type)" }.joined(separator: ","),
            "expensive": String(path.isExpensive),
            "constrained": String(path.isConstrained),
            "dns": String(path.supportsDNS)
        ]
    }

    private static func name(_ kind: PhysicalConnectionKind) -> String {
        switch kind {
        case .unknown: return "unknown"
        case .offline: return "offline"
        case .cellular: return "cellular"
        case .wifi: return "wifi"
        }
    }
}
