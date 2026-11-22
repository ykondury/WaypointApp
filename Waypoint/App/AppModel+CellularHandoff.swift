import Foundation

extension AppModel {
    /// Tests whether the already-open DVT location session survives the switch
    /// from Airplane Mode back to cellular. This deliberately never reconnects:
    /// iOS rejects a fresh developer connection when cellular is the only
    /// physical interface, while an existing session may survive the handoff.
    func armCellularHandoff() {
        guard !isChangingSimulation,
              !cellularHandoffState.isInProgress,
              let coordinate = simulatedCoordinate,
              let sessionID = simulationSessionID else {
            DiagnosticsLog.shared.record(
                "handoff",
                "arm ignored",
                metadata: [
                    "changing": String(isChangingSimulation),
                    "in_progress": String(cellularHandoffState.isInProgress),
                    "has_coordinate": String(simulatedCoordinate != nil),
                    "has_session": String(simulationSessionID != nil)
                ]
            )
            return
        }

        let operationStarted = Date()
        DiagnosticsLog.shared.record(
            "handoff",
            "armed",
            metadata: [
                "session": sessionID.uuidString,
                "lat": String(format: "%.6f", coordinate.latitude),
                "lon": String(format: "%.6f", coordinate.longitude),
                "path": CellularPathMonitor.shared.diagnosticSummary
            ]
        )

        cellularHandoffTask?.cancel()
        resendTask?.cancel()
        resendTask = nil
        _ = CellularPathMonitor.shared

        let operationID = UUID()
        cellularHandoffOperationID = operationID
        cellularHandoffState = .arming
        SimulationNotificationMonitor.shared.recordHeartbeat(for: sessionID)

        cellularHandoffTask = Task { [weak self] in
            guard let self else { return }

            // A cancelled resend may already be inside the serial bridge queue.
            // Fence it before the user changes network state.
            let fenceStarted = Date()
            await bridge.waitUntilIdle()
            DiagnosticsLog.shared.record(
                "handoff",
                "bridge fence complete",
                metadata: [
                    "session": sessionID.uuidString,
                    "fence_ms": DiagnosticsLog.elapsedMilliseconds(since: fenceStarted),
                    "path": CellularPathMonitor.shared.diagnosticSummary
                ]
            )
            guard !Task.isCancelled,
                  cellularHandoffOperationID == operationID,
                  simulationSessionID == sessionID else {
                return
            }

            let baselineStarted = Date()
            let baselineDeadline = Date().addingTimeInterval(8)
            DiagnosticsLog.shared.record(
                "handoff",
                "offline baseline wait started",
                metadata: [
                    "session": sessionID.uuidString,
                    "path": CellularPathMonitor.shared.diagnosticSummary
                ]
            )
            while !CellularPathMonitor.shared.isOffline(stableFor: 1),
                  Date() < baselineDeadline {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }

                guard !Task.isCancelled,
                      cellularHandoffOperationID == operationID,
                      simulationSessionID == sessionID else {
                    return
                }
            }

            guard CellularPathMonitor.shared.isOffline(stableFor: 1) else {
                cellularHandoffPathCheckFailed(
                    "Waypoint could not confirm the offline starting state. Turn Airplane Mode on, keep Wi-Fi off, then try the handoff again.",
                    operationID: operationID,
                    sessionID: sessionID
                )
                return
            }

            DiagnosticsLog.shared.record(
                "handoff",
                "offline baseline confirmed",
                metadata: [
                    "session": sessionID.uuidString,
                    "elapsed_ms": DiagnosticsLog.elapsedMilliseconds(since: baselineStarted),
                    "path": CellularPathMonitor.shared.diagnosticSummary
                ]
            )

            let pathStarted = Date()
            let pathDeadline = Date().addingTimeInterval(30)
            var lastDisplayedSecond: Int?
            var lastHeartbeatDate = Date()
            var lastPathLogDate = Date()
            DiagnosticsLog.shared.record(
                "handoff",
                "cellular-only wait started",
                metadata: [
                    "session": sessionID.uuidString,
                    "path": CellularPathMonitor.shared.diagnosticSummary
                ]
            )

            while !CellularPathMonitor.shared.isCellularOnly(stableFor: 2),
                  Date() < pathDeadline {
                let remaining = max(1, Int(ceil(pathDeadline.timeIntervalSinceNow)))
                if lastDisplayedSecond != remaining {
                    cellularHandoffState = .waiting(secondsRemaining: remaining)
                    lastDisplayedSecond = remaining
                }

                if Date().timeIntervalSince(lastHeartbeatDate) >= 10 {
                    SimulationNotificationMonitor.shared.recordHeartbeat(for: sessionID)
                    lastHeartbeatDate = Date()
                }

                if Date().timeIntervalSince(lastPathLogDate) >= 5 {
                    DiagnosticsLog.shared.record(
                        "handoff",
                        "cellular-only wait tick",
                        metadata: [
                            "session": sessionID.uuidString,
                            "remaining_s": String(remaining),
                            "path": CellularPathMonitor.shared.diagnosticSummary
                        ]
                    )
                    lastPathLogDate = Date()
                }

                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }

                guard !Task.isCancelled,
                      cellularHandoffOperationID == operationID,
                      simulationSessionID == sessionID else {
                    return
                }
            }

            guard CellularPathMonitor.shared.isCellularOnly(stableFor: 2) else {
                cellularHandoffPathCheckFailed(
                    "A stable cellular-only path was not detected within 30 seconds. Keep Wi-Fi off, confirm 4G/5G is working, then try again.",
                    operationID: operationID,
                    sessionID: sessionID
                )
                return
            }

            DiagnosticsLog.shared.record(
                "handoff",
                "cellular-only path confirmed",
                metadata: [
                    "session": sessionID.uuidString,
                    "elapsed_ms": DiagnosticsLog.elapsedMilliseconds(since: pathStarted),
                    "path": CellularPathMonitor.shared.diagnosticSummary
                ]
            )

            cellularHandoffState = .verifying
            SimulationNotificationMonitor.shared.recordHeartbeat(for: sessionID)

            do {
                // Reuse the retained LocationSimulation client. Calling
                // bridge.connect here would create a new socket that iOS rejects
                // on a cellular-only path.
                for probe in 1...3 {
                    guard CellularPathMonitor.shared.isCellularOnly(stableFor: 2) else {
                        cellularHandoffPathCheckFailed(
                            "The cellular-only path changed during verification. Keep Wi-Fi off and try the handoff again.",
                            operationID: operationID,
                            sessionID: sessionID
                        )
                        return
                    }

                    let probeStarted = Date()
                    DiagnosticsLog.shared.record(
                        "handoff",
                        "probe started",
                        metadata: [
                            "session": sessionID.uuidString,
                            "probe": "\(probe)/3",
                            "path": CellularPathMonitor.shared.diagnosticSummary
                        ]
                    )
                    try await bridge.setLocation(coordinate)
                    DiagnosticsLog.shared.record(
                        "handoff",
                        "probe succeeded",
                        metadata: [
                            "session": sessionID.uuidString,
                            "probe": "\(probe)/3",
                            "elapsed_ms": DiagnosticsLog.elapsedMilliseconds(since: probeStarted),
                            "path": CellularPathMonitor.shared.diagnosticSummary
                        ]
                    )
                    SimulationNotificationMonitor.shared.recordHeartbeat(for: sessionID)

                    guard CellularPathMonitor.shared.isCellularOnly() else {
                        cellularHandoffPathCheckFailed(
                            "Wi-Fi connected or cellular data dropped during verification. The cellular handoff was not confirmed.",
                            operationID: operationID,
                            sessionID: sessionID
                        )
                        return
                    }

                    if probe < 3 {
                        try await Task.sleep(for: .seconds(2))
                    }
                }
                guard !Task.isCancelled,
                      cellularHandoffOperationID == operationID,
                      simulationSessionID == sessionID else {
                    return
                }

                guard CellularPathMonitor.shared.isCellularOnly(stableFor: 2) else {
                    cellularHandoffPathCheckFailed(
                        "The cellular-only path was not stable through the final check.",
                        operationID: operationID,
                        sessionID: sessionID
                    )
                    return
                }

                DiagnosticsLog.shared.record(
                    "handoff",
                    "handoff succeeded",
                    metadata: [
                        "session": sessionID.uuidString,
                        "total_ms": DiagnosticsLog.elapsedMilliseconds(since: operationStarted),
                        "path": CellularPathMonitor.shared.diagnosticSummary
                    ]
                )
                SimulationNotificationMonitor.shared.recordHeartbeat(for: sessionID)
                cellularHandoffState = .succeeded
                cellularHandoffTask = nil
                cellularHandoffOperationID = nil
                startBackgroundKeepAliveIfNeeded()
                beginResendLoop(for: sessionID)
                publishSimulationEvent(.cellularReady)
                if case .handoff = cellularLaunchState {
                    cellularLaunchState = .succeeded
                }
            } catch {
                guard !Task.isCancelled,
                      cellularHandoffOperationID == operationID,
                      simulationSessionID == sessionID else {
                    return
                }

                var metadata = handoffErrorMetadata(error)
                metadata["session"] = sessionID.uuidString
                metadata["total_ms"] = DiagnosticsLog.elapsedMilliseconds(since: operationStarted)
                metadata["path"] = CellularPathMonitor.shared.diagnosticSummary
                DiagnosticsLog.shared.record("handoff", "handoff failed", metadata: metadata)

                cellularHandoffState = .failed(error.localizedDescription)
                cellularHandoffTask = nil
                cellularHandoffOperationID = nil
                if case .handoff = cellularLaunchState {
                    cellularLaunchState = .failed(
                        "Waypoint could not confirm the spoof after mobile data returned. Return to Wi-Fi and restart the cellular handoff.\n\n\(error.localizedDescription)"
                    )
                }
                simulationConnectionFailed(
                    error,
                    notificationSessionID: sessionID,
                    duringCellularHandoff: true
                )
            }
        }
    }

}

