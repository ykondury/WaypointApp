import Darwin
import Foundation
import IDevice

extension DeviceBridge {
    func connect(pairingFile: URL) async throws {
        let started = Date()
        DiagnosticsLog.shared.record(
            "bridge",
            "connect requested",
            metadata: ["pairing_file": pairingFile.lastPathComponent]
        )
        do {
            try await perform {
                try self.connectSynchronously(pairingPath: pairingFile.path)
            }
            DiagnosticsLog.shared.record(
                "bridge",
                "connect succeeded",
                metadata: ["elapsed_ms": DiagnosticsLog.elapsedMilliseconds(since: started)]
            )
        } catch {
            logBridgeFailure("connect failed", error: error, started: started)
            throw error
        }
    }

    private func connectSynchronously(pairingPath: String) throws {
        cleanupAll(reason: "connect")

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(Self.remotePairingPort).bigEndian

        let parsed = Self.localDevVPNAddress.withCString {
            inet_pton(AF_INET, $0, &address.sin_addr)
        }
        guard parsed == 1 else {
            throw DeviceBridgeError.message("The LocalDevVPN loopback address is invalid.")
        }

        var pairingHandle: OpaquePointer?
        let pairingStarted = Date()
        do {
            try consume(
                pairingPath.withCString { rp_pairing_file_read($0, &pairingHandle) },
                fallback: "The pairing file could not be read. Import a fresh pairing record for this iPhone."
            )
            guard let pairingHandle else {
                throw DeviceBridgeError.message("The pairing file did not create a valid pairing record.")
            }
            DiagnosticsLog.shared.record(
                "bridge",
                "pairing_file_read succeeded",
                metadata: ["elapsed_ms": DiagnosticsLog.elapsedMilliseconds(since: pairingStarted)]
            )
        } catch {
            logBridgeFailure("pairing_file_read failed", error: error, started: pairingStarted)
            throw error
        }
        guard let pairingHandle else {
            throw DeviceBridgeError.message("The pairing file did not create a valid pairing record.")
        }
        defer { rp_pairing_file_free(pairingHandle) }

        let tunnelStarted = Date()
        DiagnosticsLog.shared.record(
            "bridge",
            "tunnel_open started",
            metadata: [
                "address": Self.localDevVPNAddress,
                "port": String(Self.remotePairingPort)
            ]
        )
        let tunnelError = "Waypoint".withCString { hostName in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing(
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.stride),
                        hostName,
                        pairingHandle,
                        nil,
                        nil,
                        &adapter,
                        &handshake
                    )
                }
            }
        }

        do {
            try consume(
                tunnelError,
                fallback: "Could not reach this iPhone through LocalDevVPN."
            )
            guard adapter != nil, handshake != nil else {
                throw DeviceBridgeError.message("The developer tunnel opened without valid connection handles.")
            }
            DiagnosticsLog.shared.record(
                "bridge",
                "tunnel_open succeeded",
                metadata: ["elapsed_ms": DiagnosticsLog.elapsedMilliseconds(since: tunnelStarted)]
            )
        } catch {
            logBridgeFailure("tunnel_open failed", error: error, started: tunnelStarted)
            cleanupAll(reason: "tunnel_open_failed")
            throw error
        }
    }
}
