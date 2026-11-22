import Foundation
import UIKit

extension AppModel {
    func refreshLocalState() {
        refreshLocalDevVPNAvailability()
        refreshSideStoreAvailability()
        refreshDisconnectAlertSettings()
        pairingState = PairingFileStore.exists ? .ready : .required
        DiagnosticsLog.shared.record(
            "lifecycle",
            "local state refreshed",
            metadata: [
                "pairing": String(PairingFileStore.exists),
                "localdevvpn": String(isLocalDevVPNInstalled),
                "path": CellularPathMonitor.shared.diagnosticSummary
            ]
        )

        if SimulationNotificationMonitor.shared.consumeStaleSessionMarker() {
            DiagnosticsLog.shared.record("lifecycle", "stale simulation session marker consumed")
            publishSimulationEvent(.connectionLost)
            presentError(
                title: "Previous Spoof Session Ended",
                message: "Waypoint was closed while spoofing. The developer connection is no longer being maintained, so verify your location before continuing."
            )
        }

        if !PairingFileStore.exists {
            tunnelState = .required
            developerImageState = .required
        }
    }

    func setDisconnectAlertsEnabled(_ enabled: Bool) {
        let operationID = UUID()
        notificationSettingsOperationID = operationID
        hasStoredDisconnectAlertsPreference = true
        disconnectAlertsPreference = enabled
        UserDefaults.standard.set(enabled, forKey: Self.disconnectAlertsKey)

        guard enabled else {
            disconnectAlertsEnabled = false
            disconnectAlertsDenied = false
            isUpdatingDisconnectAlerts = false
            SimulationNotificationMonitor.shared.setAlertsEnabled(false)
            notificationSettingsOperationID = nil
            return
        }

        isUpdatingDisconnectAlerts = true
        Task { [weak self] in
            guard let self else { return }
            let authorization = await SimulationNotificationMonitor.shared.requestAuthorization()
            applyDisconnectAlertAuthorization(authorization, operationID: operationID)
        }
    }

    func checkLocalDevVPNInstallation() {
        continueGuidedLaunchAfterLocalDevVPNIfNeeded()
    }

    func refreshLocalDevVPNAvailability() {
        guard let url = localDevVPNEnableURL() else {
            isLocalDevVPNInstalled = false
            return
        }
        isLocalDevVPNInstalled = UIApplication.shared.canOpenURL(url)
    }

    private func refreshSideStoreAvailability() {
        guard let url = sideStorePairingURL() else {
            isSideStoreAvailable = false
            return
        }
        isSideStoreAvailable = UIApplication.shared.canOpenURL(url)
    }

    func sideStorePairingURL() -> URL? {
        var components = URLComponents()
        components.scheme = "sidestore"
        components.host = "pairing"
        components.queryItems = [URLQueryItem(name: "urlname", value: Self.pairingCallbackScheme)]
        return components.url
    }

    func localDevVPNEnableURL() -> URL? {
        var components = URLComponents()
        components.scheme = "localdevvpn"
        components.host = "enable"
        components.queryItems = [
            URLQueryItem(name: "scheme", value: Self.pairingCallbackScheme)
        ]
        return components.url
    }


    private func refreshDisconnectAlertSettings() {
        let operationID = UUID()
        notificationSettingsOperationID = operationID
        isUpdatingDisconnectAlerts = true

        Task { [weak self] in
            guard let self else { return }
            let authorization = await SimulationNotificationMonitor.shared.authorizationState()
            guard notificationSettingsOperationID == operationID else { return }

            if !hasStoredDisconnectAlertsPreference {
                hasStoredDisconnectAlertsPreference = true
                disconnectAlertsPreference = authorization == .authorized
                UserDefaults.standard.set(disconnectAlertsPreference, forKey: Self.disconnectAlertsKey)
            }

            applyDisconnectAlertAuthorization(authorization, operationID: operationID)
        }
    }

    private func applyDisconnectAlertAuthorization(
        _ authorization: SimulationNotificationAuthorization,
        operationID: UUID
    ) {
        guard notificationSettingsOperationID == operationID else { return }

        let enabled = disconnectAlertsPreference && authorization == .authorized
        disconnectAlertsEnabled = enabled
        disconnectAlertsDenied = disconnectAlertsPreference && authorization == .denied
        isUpdatingDisconnectAlerts = false
        notificationSettingsOperationID = nil
        SimulationNotificationMonitor.shared.setAlertsEnabled(enabled)
    }

    func applicationBecameActive() {
        isApplicationActive = true
        DiagnosticsLog.shared.record(
            "lifecycle",
            "application became active",
            metadata: [
                "launch_state": String(describing: cellularLaunchState),
                "handoff_state": String(describing: cellularHandoffState),
                "path": CellularPathMonitor.shared.diagnosticSummary
            ]
        )
        refreshLocalDevVPNAvailability()
        refreshSideStoreAvailability()
        refreshDisconnectAlertSettings()
        if isLocalDevVPNInstalled,
           case .needsLocalDevVPN = cellularLaunchState {
            continueGuidedLaunchAfterLocalDevVPNIfNeeded()
        }
        if case .openingLocalDevVPN = cellularLaunchState,
           didLeaveForLocalDevVPN {
            localDevVPNDidReturn()
        }
        guard cellularLaunchOperationID == nil else { return }
        guard !cellularHandoffState.pausesLocationWrites else { return }
        guard let coordinate = simulatedCoordinate,
              let sessionID = simulationSessionID else { return }

        Task {
            do {
                try await bridge.setLocation(coordinate)
                guard simulationSessionID == sessionID else { return }
                SimulationNotificationMonitor.shared.recordHeartbeat(for: sessionID)
                DiagnosticsLog.shared.record(
                    "lifecycle",
                    "foreground location refresh succeeded",
                    metadata: ["session": sessionID.uuidString]
                )
            } catch {
                guard simulationSessionID == sessionID else { return }
                DiagnosticsLog.shared.record(
                    "lifecycle",
                    "foreground location refresh failed",
                    metadata: [
                        "session": sessionID.uuidString,
                        "error": error.localizedDescription,
                        "path": CellularPathMonitor.shared.diagnosticSummary
                    ]
                )
                simulationConnectionFailed(error, notificationSessionID: sessionID)
            }
        }
    }

    func applicationBecameInactive() {
        isApplicationActive = false
        DiagnosticsLog.shared.record(
            "lifecycle",
            "application became inactive",
            metadata: [
                "launch_state": String(describing: cellularLaunchState),
                "handoff_state": String(describing: cellularHandoffState),
                "path": CellularPathMonitor.shared.diagnosticSummary
            ]
        )
        if case .openingLocalDevVPN = cellularLaunchState {
            didLeaveForLocalDevVPN = true
        }
    }
}

