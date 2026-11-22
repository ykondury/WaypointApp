import Foundation

extension AppModel {
    func cancelCellularHandoff() {
        guard cellularHandoffState.isInProgress else { return }
        let sessionID = simulationSessionID
        DiagnosticsLog.shared.record(
            "handoff",
            "cancel requested",
            metadata: [
                "state": String(describing: cellularHandoffState),
                "path": CellularPathMonitor.shared.diagnosticSummary
            ]
        )

        switch cellularHandoffState {
        case .arming:
            cancelCellularHandoffWork(resetState: true)
            if let sessionID, simulatedCoordinate != nil {
                beginResendLoop(for: sessionID)
            }
        case .waiting, .verifying:
            cancelCellularHandoffWork(resetState: false)
            cellularHandoffState = .failed(
                "The handoff was cancelled after the network transition began. Location writes remain paused until you return to Airplane Mode or Wi-Fi and explicitly resume."
            )
            if let sessionID {
                SimulationNotificationMonitor.shared.recordHeartbeat(for: sessionID)
            }
        case .idle, .succeeded, .failed:
            return
        }
    }

    func resumeSimulationAfterHandoffFailure() {
        guard case .failed = cellularHandoffState,
              let sessionID = simulationSessionID,
              simulatedCoordinate != nil else {
            return
        }

        DiagnosticsLog.shared.record(
            "handoff",
            "resume after failure",
            metadata: [
                "session": sessionID.uuidString,
                "path": CellularPathMonitor.shared.diagnosticSummary
            ]
        )
        cellularHandoffState = .idle
        SimulationNotificationMonitor.shared.recordHeartbeat(for: sessionID)
        beginResendLoop(for: sessionID)
    }

    func cellularHandoffPathCheckFailed(
        _ message: String,
        operationID: UUID,
        sessionID: UUID
    ) {
        guard cellularHandoffOperationID == operationID,
              simulationSessionID == sessionID else {
            return
        }

        DiagnosticsLog.shared.record(
            "handoff",
            "path check failed",
            metadata: [
                "session": sessionID.uuidString,
                "message": message,
                "path": CellularPathMonitor.shared.diagnosticSummary
            ]
        )
        cellularHandoffState = .failed(message)
        cellularHandoffTask = nil
        cellularHandoffOperationID = nil
        SimulationNotificationMonitor.shared.recordHeartbeat(for: sessionID)
        if case .handoff = cellularLaunchState {
            cellularLaunchState = .failed(message)
        }
    }

    func cancelCellularHandoffWork(resetState: Bool) {
        if cellularHandoffTask != nil || cellularHandoffOperationID != nil {
            DiagnosticsLog.shared.record(
                "handoff",
                "cancel work",
                metadata: [
                    "reset_state": String(resetState),
                    "state": String(describing: cellularHandoffState),
                    "path": CellularPathMonitor.shared.diagnosticSummary
                ]
            )
        }
        cellularHandoffTask?.cancel()
        cellularHandoffTask = nil
        cellularHandoffOperationID = nil
        if resetState {
            cellularHandoffState = .idle
        }
    }

    func handoffErrorMetadata(_ error: Error) -> [String: String] {
        var metadata = ["error": error.localizedDescription]
        if let bridgeError = error as? DeviceBridgeError {
            metadata["error_name"] = bridgeError.diagnosticName
            if let code = bridgeError.diagnosticCode {
                metadata["ffi_code"] = String(code)
                metadata["timeout"] = String(code == DeviceBridgeError.nativeTimeoutCode)
            }
        }
        return metadata
    }
}
