import Foundation
import UIKit

extension AppModel {
    func localDevVPNDidReturn() {
        guard case .openingLocalDevVPN = cellularLaunchState,
              let operationID = cellularLaunchOperationID else {
            return
        }

        didLeaveForLocalDevVPN = false
        cellularLaunchTask?.cancel()
        cellularLaunchState = .settlingLocalDevVPN
        DiagnosticsLog.shared.record(
            "guided",
            "localdevvpn returned",
            metadata: [
                "operation": operationID.uuidString,
                "path": CellularPathMonitor.shared.diagnosticSummary
            ]
        )
        cellularLaunchTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }

            guard !Task.isCancelled,
                  cellularLaunchOperationID == operationID else {
                return
            }

            if pendingLaunchRoute == .wifi {
                await startGuidedSimulationOnWiFi(operationID: operationID)
            } else {
                await waitForOfflineAndStart(operationID: operationID)
            }
        }
    }

    private func startGuidedSimulationOnWiFi(operationID: UUID) async {
        guard cellularLaunchOperationID == operationID,
              pendingLaunchRoute == .wifi,
              let coordinate = pendingCellularCoordinate else {
            return
        }

        guard CellularPathMonitor.shared.activeConnection == .wifi else {
            failCellularLaunch(
                "Wi-Fi disconnected before Waypoint could start. Reconnect Wi-Fi and try again, or close this guide to use mobile data.",
                operationID: operationID
            )
            return
        }

        do {
            cellularLaunchState = .preparingDevice
            DiagnosticsLog.shared.record(
                "guided",
                "wifi launch preparing device",
                metadata: [
                    "operation": operationID.uuidString,
                    "path": CellularPathMonitor.shared.diagnosticSummary
                ]
            )
            try await prepareDeviceCore()
            try Task.checkCancellation()

            guard cellularLaunchOperationID == operationID,
                  pendingLaunchRoute == .wifi else { return }
            cellularLaunchState = .startingSpoof
            try await establishGuidedSimulation(at: coordinate, operationID: operationID)
            try Task.checkCancellation()

            guard cellularLaunchOperationID == operationID,
                  simulatedCoordinate != nil,
                  let sessionID = simulationSessionID else {
                return
            }

            startBackgroundKeepAliveIfNeeded()
            beginResendLoop(for: sessionID)
            cellularLaunchTask = nil
            cellularLaunchState = .succeeded
            DiagnosticsLog.shared.record(
                "guided",
                "wifi launch succeeded",
                metadata: [
                    "operation": operationID.uuidString,
                    "session": sessionID.uuidString,
                    "path": CellularPathMonitor.shared.diagnosticSummary
                ]
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  cellularLaunchOperationID == operationID else { return }
            DiagnosticsLog.shared.record(
                "guided",
                "wifi launch failed",
                metadata: [
                    "operation": operationID.uuidString,
                    "error": error.localizedDescription,
                    "path": CellularPathMonitor.shared.diagnosticSummary
                ]
            )
            if case .preparingDevice = cellularLaunchState {
                await recordPreparationFailure(error)
            } else {
                invalidateConnectionReadiness()
                await bridge.disconnect()
            }
            failCellularLaunch(
                "Waypoint could not start the spoof on Wi-Fi. Confirm LocalDevVPN and Developer Mode are enabled, then try again.\n\n\(error.localizedDescription)",
                operationID: operationID
            )
        }
    }

    private func waitForOfflineAndStart(operationID: UUID) async {
        cellularLaunchState = .waitingForAirplaneMode
        DiagnosticsLog.shared.record(
            "guided",
            "waiting for airplane mode",
            metadata: [
                "operation": operationID.uuidString,
                "path": CellularPathMonitor.shared.diagnosticSummary
            ]
        )

        while cellularLaunchOperationID == operationID {
            if isApplicationActive,
               CellularPathMonitor.shared.isOffline(stableFor: 1) {
                break
            }

            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
        }

        guard !Task.isCancelled,
              cellularLaunchOperationID == operationID,
              let coordinate = pendingCellularCoordinate else {
            return
        }

        DiagnosticsLog.shared.record(
            "guided",
            "offline confirmed; starting spoof",
            metadata: [
                "operation": operationID.uuidString,
                "path": CellularPathMonitor.shared.diagnosticSummary
            ]
        )

        do {
            cellularLaunchState = .preparingDevice
            try await prepareDeviceCore()
            try Task.checkCancellation()

            guard cellularLaunchOperationID == operationID else { return }
            cellularLaunchState = .startingSpoof
            try await establishGuidedSimulation(at: coordinate, operationID: operationID)
            try Task.checkCancellation()

            guard cellularLaunchOperationID == operationID,
                  simulatedCoordinate != nil,
                  simulationSessionID != nil else {
                return
            }

            DiagnosticsLog.shared.record(
                "guided",
                "arming handoff after offline spoof start",
                metadata: [
                    "operation": operationID.uuidString,
                    "path": CellularPathMonitor.shared.diagnosticSummary
                ]
            )
            cellularLaunchState = .handoff
            cellularLaunchTask = nil
            armCellularHandoff()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  cellularLaunchOperationID == operationID else { return }
            DiagnosticsLog.shared.record(
                "guided",
                "offline launch failed",
                metadata: [
                    "operation": operationID.uuidString,
                    "error": error.localizedDescription,
                    "path": CellularPathMonitor.shared.diagnosticSummary
                ]
            )
            if case .preparingDevice = cellularLaunchState {
                await recordPreparationFailure(error)
            } else {
                invalidateConnectionReadiness()
                await bridge.disconnect()
            }
            failCellularLaunch(
                "Waypoint could not start the spoof. Confirm Developer Mode is enabled, then try again.\n\n\(error.localizedDescription)",
                operationID: operationID
            )
        }
    }

    private func establishGuidedSimulation(
        at coordinate: SelectedCoordinate,
        operationID: UUID
    ) async throws {
        guard coordinate.isValid,
              simulatedCoordinate == nil,
              simulationSessionID == nil,
              cellularLaunchOperationID == operationID else {
            throw DeviceBridgeError.message("The guided start is no longer current.")
        }

        isChangingSimulation = true
        defer { isChangingSimulation = false }
        resendTask?.cancel()
        resendTask = nil

        try await bridge.setLocation(coordinate)
        try Task.checkCancellation()

        guard cellularLaunchOperationID == operationID else {
            try? await bridge.clearLocation()
            throw CancellationError()
        }

        let sessionID = UUID()
        simulationSessionID = sessionID
        simulatedCoordinate = coordinate
        UIApplication.shared.isIdleTimerDisabled = true
        SimulationNotificationMonitor.shared.beginSession(sessionID)
        DiagnosticsLog.shared.record(
            "guided",
            "spoof established",
            metadata: [
                "operation": operationID.uuidString,
                "session": sessionID.uuidString,
                "path": CellularPathMonitor.shared.diagnosticSummary
            ]
        )
        publishSimulationEvent(.started, coordinate: coordinate)
    }

    func startBackgroundKeepAliveIfNeeded() {
        guard backgroundKeepAliveEnabled else { return }
        do {
            try BackgroundKeepAlive.shared.start()
            DiagnosticsLog.shared.record("keepalive", "started")
        } catch {
            DiagnosticsLog.shared.record(
                "keepalive",
                "start failed",
                metadata: ["error": error.localizedDescription]
            )
            presentError(
                title: "Background Keepalive Unavailable",
                message: "The spoof is active, but background reliability may be reduced.\n\n\(error.localizedDescription)"
            )
        }
    }
}

