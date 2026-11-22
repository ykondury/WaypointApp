import Foundation
import UIKit

extension AppModel {
    func startSimulation(at coordinate: SelectedCoordinate) async {
        guard cellularLaunchOperationID == nil else { return }
        guard coordinate.isValid else {
            presentError(title: "Invalid Location", message: "Choose a valid point on the map.")
            return
        }

        DiagnosticsLog.shared.record(
            "simulation",
            "start requested",
            metadata: [
                "lat": String(format: "%.6f", coordinate.latitude),
                "lon": String(format: "%.6f", coordinate.longitude),
                "path": CellularPathMonitor.shared.diagnosticSummary
            ]
        )

        if !isReady {
            await prepareDevice()
        }
        guard isReady else {
            isSetupPresented = true
            return
        }

        guard !isChangingSimulation else { return }
        if simulatedCoordinate == nil {
            if case .failed = cellularHandoffState {
                cancelCellularHandoffWork(resetState: true)
            }
        }
        guard !cellularHandoffState.pausesLocationWrites else { return }

        let previousCoordinate = simulatedCoordinate
        let previousSessionID = simulationSessionID

        if previousCoordinate == nil {
            cancelCellularHandoffWork(resetState: true)
        }

        isChangingSimulation = true
        resendTask?.cancel()
        resendTask = nil
        simulationSessionID = nil

        do {
            try await bridge.setLocation(coordinate)

            if let previousSessionID {
                SimulationNotificationMonitor.shared.endSession(previousSessionID)
            }

            let sessionID = UUID()
            simulationSessionID = sessionID
            simulatedCoordinate = coordinate
            UIApplication.shared.isIdleTimerDisabled = true
            SimulationNotificationMonitor.shared.beginSession(sessionID)

            if backgroundKeepAliveEnabled {
                do {
                    try BackgroundKeepAlive.shared.start()
                } catch {
                    presentError(
                        title: "Background Keepalive Unavailable",
                        message: "The location was set, but background reliability may be reduced.\n\n\(error.localizedDescription)"
                    )
                }
            }
            beginResendLoop(for: sessionID)
            publishSimulationEvent(previousCoordinate == nil ? .started : .moved, coordinate: coordinate)
            DiagnosticsLog.shared.record(
                "simulation",
                "start succeeded",
                metadata: [
                    "session": sessionID.uuidString,
                    "path": CellularPathMonitor.shared.diagnosticSummary
                ]
            )
        } catch {
            DiagnosticsLog.shared.record(
                "simulation",
                "start failed",
                metadata: [
                    "error": error.localizedDescription,
                    "path": CellularPathMonitor.shared.diagnosticSummary
                ]
            )
            if previousCoordinate != nil, let previousSessionID {
                simulationConnectionFailed(
                    error,
                    notificationSessionID: previousSessionID,
                    requireCurrentSession: false
                )
            } else {
                invalidateConnectionReadiness()
                isSetupPresented = true
                presentError(title: "Location Simulation Failed", error: error)
            }
        }
        isChangingSimulation = false
    }

    func stopSimulation() async {
        guard cellularLaunchOperationID == nil else { return }
        guard !isChangingSimulation else { return }

        DiagnosticsLog.shared.record(
            "simulation",
            "stop requested",
            metadata: ["path": CellularPathMonitor.shared.diagnosticSummary]
        )
        cancelCellularHandoffWork(resetState: true)
        let sessionID = simulationSessionID
        isChangingSimulation = true
        isStoppingSimulation = true
        simulationSessionID = nil
        resendTask?.cancel()
        resendTask = nil

        if let sessionID {
            SimulationNotificationMonitor.shared.endSession(sessionID)
        }

        var didConfirmStop = false

        do {
            try await bridge.clearLocation()
            didConfirmStop = true
        } catch {
            DiagnosticsLog.shared.record(
                "simulation",
                "stop failed",
                metadata: ["error": error.localizedDescription]
            )
            invalidateConnectionReadiness()
            presentError(
                title: "Could Not Confirm Real Location",
                message: "Waypoint lost the simulation connection. Disconnect LocalDevVPN or reboot if another app still reports the simulated point.\n\n\(error.localizedDescription)"
            )
        }

        simulatedCoordinate = nil
        BackgroundKeepAlive.shared.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        if didConfirmStop {
            publishSimulationEvent(.stopped)
            DiagnosticsLog.shared.record("simulation", "stop succeeded")
        }
        isStoppingSimulation = false
        isChangingSimulation = false
    }

    func beginResendLoop(for sessionID: UUID) {
        guard !cellularHandoffState.pausesLocationWrites else { return }
        resendTask?.cancel()
        DiagnosticsLog.shared.record(
            "simulation",
            "resend loop started",
            metadata: [
                "session": sessionID.uuidString,
                "path": CellularPathMonitor.shared.diagnosticSummary
            ]
        )
        resendTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled,
                      let self,
                      !self.cellularHandoffState.pausesLocationWrites,
                      self.simulationSessionID == sessionID,
                      let coordinate = self.simulatedCoordinate else {
                    return
                }

                if case .succeeded = self.cellularHandoffState,
                   !CellularPathMonitor.shared.isCellularOnly() {
                    DiagnosticsLog.shared.record(
                        "simulation",
                        "cellular path lost; pausing writes",
                        metadata: [
                            "session": sessionID.uuidString,
                            "path": CellularPathMonitor.shared.diagnosticSummary
                        ]
                    )
                    self.cellularHandoffState = .failed(
                        "The phone is no longer on a cellular-only path. Location writes are paused so Waypoint does not make an unsafe cellular-only reconnect attempt."
                    )
                    SimulationNotificationMonitor.shared.recordHeartbeat(for: sessionID)
                    if case .succeeded = self.cellularLaunchState {
                        self.cellularLaunchState = .failed(
                            "The cellular-only path changed before setup finished."
                        )
                    }
                    return
                }

                do {
                    try await self.bridge.setLocation(coordinate)
                    guard !Task.isCancelled, self.simulationSessionID == sessionID else { return }
                    SimulationNotificationMonitor.shared.recordHeartbeat(for: sessionID)
                } catch {
                    guard !Task.isCancelled, self.simulationSessionID == sessionID else { return }
                    DiagnosticsLog.shared.record(
                        "simulation",
                        "resend failed",
                        metadata: [
                            "session": sessionID.uuidString,
                            "error": error.localizedDescription,
                            "path": CellularPathMonitor.shared.diagnosticSummary
                        ]
                    )
                    self.simulationConnectionFailed(error, notificationSessionID: sessionID)
                    return
                }
            }
        }
    }

    func simulationConnectionFailed(
        _ error: Error,
        notificationSessionID: UUID,
        requireCurrentSession: Bool = true,
        duringCellularHandoff: Bool = false
    ) {
        if requireCurrentSession, simulationSessionID != notificationSessionID { return }
        guard !isStoppingSimulation, simulatedCoordinate != nil else { return }

        var failureMetadata = [
            "session": notificationSessionID.uuidString,
            "during_handoff": String(duringCellularHandoff),
            "error": error.localizedDescription,
            "path": CellularPathMonitor.shared.diagnosticSummary
        ]
        if let bridgeError = error as? DeviceBridgeError {
            failureMetadata["error_name"] = bridgeError.diagnosticName
            if let code = bridgeError.diagnosticCode {
                failureMetadata["ffi_code"] = String(code)
                failureMetadata["timeout"] = String(code == DeviceBridgeError.nativeTimeoutCode)
            }
        }
        DiagnosticsLog.shared.record("simulation", "connection failed", metadata: failureMetadata)

        resendTask?.cancel()
        resendTask = nil
        cancelCellularHandoffWork(resetState: !duringCellularHandoff)
        simulationSessionID = nil
        simulatedCoordinate = nil
        BackgroundKeepAlive.shared.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        SimulationNotificationMonitor.shared.reportUnexpectedStop(for: notificationSessionID)
        invalidateConnectionReadiness()
        if !duringCellularHandoff {
            isSetupPresented = true
        }
        publishSimulationEvent(.connectionLost)
        if duringCellularHandoff {
            cellularHandoffState = .idle
            if cellularLaunchOperationID == nil {
                presentError(
                    title: "Cellular Handoff Failed",
                    message: "The retained developer session stopped responding during mobile-data verification, so Waypoint could not confirm that the spoof is still active. Return to Wi-Fi, reconnect LocalDevVPN, and restart the spoof before trying again.\n\n\(error.localizedDescription)"
                )
            } else if case .handoff = cellularLaunchState {
                cellularLaunchState = .failed(
                    "Waypoint could not confirm the spoof after mobile data returned. Return to Wi-Fi and restart the cellular handoff.\n\n\(error.localizedDescription)"
                )
            }
        } else {
            presentError(
                title: "Simulation Connection Ended",
                message: "The developer connection closed, so iOS may have returned to the real location.\n\n\(error.localizedDescription)"
            )
        }
    }
}

