import CoreServices
import Foundation

public enum AutomationStatus: Equatable, Sendable {
    case granted
    case denied
    case undetermined
    case playerNotRunning
}

/// Reads made without permission return 0 and no error, so a reading alone
/// cannot be trusted. This asks the system directly.
public enum AutomationPermission {
    /// With `ask` set this can show the system prompt and blocks until it is
    /// answered, so keep it off the main thread.
    public static func status(bundleID: String, ask: Bool) -> AutomationStatus {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), bytes, bytes.count, &target) == noErr else {
            return .undetermined
        }
        defer { AEDisposeDesc(&target) }

        switch AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask) {
        case OSStatus(noErr): return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .undetermined
        default: return .playerNotRunning
        }
    }
}
