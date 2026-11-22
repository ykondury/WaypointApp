import Foundation

enum DeviceBridgeError: LocalizedError, Sendable {
    /// IdeviceError::Timeout in the pinned idevice FFI returns code 109.
    static let nativeTimeoutCode = 109

    case invalidCoordinate
    case ffi(code: Int, message: String)
    case locationWriteTimedOut(seconds: Int)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .invalidCoordinate:
            return "Choose a valid latitude and longitude."
        case .ffi(let code, let message):
            return "\(message) (idevice error \(code))"
        case .locationWriteTimedOut(let seconds):
            return "iOS did not acknowledge the simulated location within \(seconds) seconds. Waypoint closed the timed-out DVT session so it cannot keep blocking or consume a stale reply. Reconnect LocalDevVPN over Wi-Fi before restarting the simulation or retrying the cellular handoff."
        case .message(let message):
            return message
        }
    }

    var diagnosticCode: Int? {
        switch self {
        case .ffi(let code, _):
            return code
        case .locationWriteTimedOut:
            return Self.nativeTimeoutCode
        case .invalidCoordinate, .message:
            return nil
        }
    }

    var diagnosticName: String {
        switch self {
        case .invalidCoordinate:
            return "invalid_coordinate"
        case .ffi:
            return "ffi_error"
        case .locationWriteTimedOut:
            return "location_write_timeout"
        case .message:
            return "bridge_message"
        }
    }
}
