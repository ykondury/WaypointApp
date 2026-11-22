import Darwin
import Foundation
import IDevice

final class DeviceBridge: @unchecked Sendable {
    static let localDevVPNAddress = "10.7.0.1"
    static let remotePairingPort: UInt16 = 49_152

    private let queue = DispatchQueue(label: "app.waypoint.device-bridge", qos: .userInitiated)
    private static let locationWriteTimeoutSeconds = 8

    var adapter: OpaquePointer?
    var handshake: OpaquePointer?
    private var remoteServer: OpaquePointer?
    private var locationClient: OpaquePointer?
    deinit {
        cleanupAll()
    }

    func isDeveloperImageMounted() async throws -> Bool {
        try await perform {
            try self.requireTunnel()
            return try self.mountedImageCount() > 0
        }
    }

    func mountDeveloperImage(_ paths: DeveloperImagePaths) async throws {
        try await perform {
            try self.requireTunnel()
            if try self.mountedImageCount() > 0 { return }
            try self.mountDeveloperImageSynchronously(paths)
        }
    }

    func setLocation(_ coordinate: SelectedCoordinate) async throws {
        let requestedAt = Date()
        DiagnosticsLog.shared.record(
            "bridge",
            "set_location requested",
            metadata: [
                "lat": String(format: "%.6f", coordinate.latitude),
                "lon": String(format: "%.6f", coordinate.longitude)
            ]
        )
        do {
            try await perform {
                guard coordinate.isValid else { throw DeviceBridgeError.invalidCoordinate }
                try self.requireTunnel()
                try self.ensureLocationClient()
                guard let locationClient = self.locationClient else {
                    throw DeviceBridgeError.message("The location-simulation client was not created.")
                }

                let writeStarted = Date()
                do {
                    try self.consumeLocationSimulationSet(
                        location_simulation_set(locationClient, coordinate.latitude, coordinate.longitude),
                        fallback: "The device rejected the simulated location."
                    )
                    DiagnosticsLog.shared.record(
                        "bridge",
                        "location_write succeeded",
                        metadata: ["ffi_ms": DiagnosticsLog.elapsedMilliseconds(since: writeStarted)]
                    )
                } catch {
                    let bridgeError = error as? DeviceBridgeError
                    var fields = [
                        "error": error.localizedDescription,
                        "ffi_ms": DiagnosticsLog.elapsedMilliseconds(since: writeStarted)
                    ]
                    if let bridgeError {
                        fields["error_name"] = bridgeError.diagnosticName
                        if let code = bridgeError.diagnosticCode {
                            fields["ffi_code"] = String(code)
                            fields["timeout"] = String(code == DeviceBridgeError.nativeTimeoutCode)
                        }
                    }
                    DiagnosticsLog.shared.record("bridge", "location_write failed", metadata: fields)
                    self.cleanupAll(reason: bridgeError?.diagnosticName ?? "location_write_failed")
                    throw error
                }
            }
            DiagnosticsLog.shared.record(
                "bridge",
                "set_location returned",
                metadata: ["total_ms": DiagnosticsLog.elapsedMilliseconds(since: requestedAt)]
            )
        } catch {
            logBridgeFailure("set_location failed", error: error, started: requestedAt)
            throw error
        }
    }

    func clearLocation() async throws {
        let started = Date()
        DiagnosticsLog.shared.record("bridge", "clear_location requested")
        do {
            try await perform {
                try self.requireTunnel()
                try self.ensureLocationClient()
                guard let locationClient = self.locationClient else {
                    throw DeviceBridgeError.message("The location-simulation client was not created.")
                }

                do {
                    try self.consume(
                        location_simulation_clear(locationClient),
                        fallback: "The device could not restore its real location."
                    )
                    self.cleanupLocationSession(reason: "clear_location")
                    DiagnosticsLog.shared.record("bridge", "clear_location succeeded")
                } catch {
                    self.cleanupAll(reason: "clear_location_failed")
                    throw error
                }
            }
            DiagnosticsLog.shared.record(
                "bridge",
                "clear_location returned",
                metadata: ["elapsed_ms": DiagnosticsLog.elapsedMilliseconds(since: started)]
            )
        } catch {
            logBridgeFailure("clear_location failed", error: error, started: started)
            throw error
        }
    }

    func disconnect() async {
        let started = Date()
        DiagnosticsLog.shared.record("bridge", "disconnect requested")
        await withCheckedContinuation { continuation in
            queue.async {
                self.cleanupAll(reason: "disconnect")
                continuation.resume()
            }
        }
        DiagnosticsLog.shared.record(
            "bridge",
            "disconnect finished",
            metadata: ["elapsed_ms": DiagnosticsLog.elapsedMilliseconds(since: started)]
        )
    }

    /// Waits until every previously submitted bridge operation has finished.
    /// The cellular handoff uses this fence before changing network state so a
    /// periodic location write cannot collide with the transition.
    func waitUntilIdle() async {
        let started = Date()
        DiagnosticsLog.shared.record("bridge", "fence requested")
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
        DiagnosticsLog.shared.record(
            "bridge",
            "fence reached",
            metadata: ["wait_ms": DiagnosticsLog.elapsedMilliseconds(since: started)]
        )
    }

    func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }

    private func requireTunnel() throws {
        guard adapter != nil, handshake != nil else {
            throw DeviceBridgeError.message("Prepare the device before starting location simulation.")
        }
    }

    private func ensureLocationClient() throws {
        if locationClient != nil { return }
        guard let adapter, let handshake else {
            throw DeviceBridgeError.message("The developer tunnel is not connected.")
        }

        let started = Date()
        do {
            cleanupLocationSession(reason: "recreate_location_client")
            DiagnosticsLog.shared.record("bridge", "dvt_connect started")
            try consume(
                remote_server_connect_rsd(adapter, handshake, &remoteServer),
                fallback: "Could not connect to the DVT developer service."
            )
            guard let remoteServer else {
                throw DeviceBridgeError.message("The DVT developer service did not return a client.")
            }
            DiagnosticsLog.shared.record(
                "bridge",
                "dvt_connect succeeded",
                metadata: ["elapsed_ms": DiagnosticsLog.elapsedMilliseconds(since: started)]
            )

            try consume(
                location_simulation_new(remoteServer, &locationClient),
                fallback: "The location-simulation service is unavailable. Check that the developer image is mounted."
            )
            guard locationClient != nil else {
                throw DeviceBridgeError.message("The location-simulation service did not return a client.")
            }
            DiagnosticsLog.shared.record(
                "bridge",
                "location_client created",
                metadata: ["elapsed_ms": DiagnosticsLog.elapsedMilliseconds(since: started)]
            )
        } catch {
            logBridgeFailure("location_client creation failed", error: error, started: started)
            cleanupAll(reason: "location_client_failed")
            throw error
        }
    }

    func consume(
        _ ffiError: UnsafeMutablePointer<IdeviceFfiError>?,
        fallback: String
    ) throws {
        guard let ffiError else { return }

        let code = Int(ffiError.pointee.code)
        let message = ffiError.pointee.message.flatMap(String.init(validatingUTF8:)) ?? fallback
        idevice_error_free(ffiError)
        throw DeviceBridgeError.ffi(code: code, message: message)
    }

    private func consumeLocationSimulationSet(
        _ ffiError: UnsafeMutablePointer<IdeviceFfiError>?,
        fallback: String
    ) throws {
        guard let ffiError else { return }

        let code = Int(ffiError.pointee.code)
        let message = ffiError.pointee.message.flatMap(String.init(validatingUTF8:)) ?? fallback
        idevice_error_free(ffiError)

        if code == DeviceBridgeError.nativeTimeoutCode {
            throw DeviceBridgeError.locationWriteTimedOut(seconds: Self.locationWriteTimeoutSeconds)
        }

        throw DeviceBridgeError.ffi(code: code, message: message)
    }

    private func cleanupLocationSession(reason: String = "unspecified") {
        guard locationClient != nil || remoteServer != nil else { return }
        DiagnosticsLog.shared.record(
            "bridge",
            "location_session cleanup",
            metadata: [
                "reason": reason,
                "location_client": String(locationClient != nil),
                "remote_server": String(remoteServer != nil)
            ]
        )
        if let locationClient {
            location_simulation_free(locationClient)
            self.locationClient = nil
        }
        if let remoteServer {
            remote_server_free(remoteServer)
            self.remoteServer = nil
        }
    }

    func cleanupAll(reason: String = "unspecified") {
        let hadHandshake = handshake != nil
        let hadAdapter = adapter != nil
        cleanupLocationSession(reason: reason)
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
        if hadHandshake || hadAdapter {
            DiagnosticsLog.shared.record(
                "bridge",
                "tunnel cleanup",
                metadata: [
                    "reason": reason,
                    "handshake": String(hadHandshake),
                    "adapter": String(hadAdapter)
                ]
            )
        }
    }

    func logBridgeFailure(
        _ message: String,
        error: Error,
        started: Date,
        metadata: [String: String] = [:]
    ) {
        var fields = metadata
        fields["elapsed_ms"] = DiagnosticsLog.elapsedMilliseconds(since: started)
        fields["error"] = error.localizedDescription
        if let bridgeError = error as? DeviceBridgeError {
            fields["error_name"] = bridgeError.diagnosticName
            if let code = bridgeError.diagnosticCode {
                fields["ffi_code"] = String(code)
            }
        }
        DiagnosticsLog.shared.record("bridge", message, metadata: fields)
    }
}
