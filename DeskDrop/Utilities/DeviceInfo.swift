import Foundation
import IOKit.ps

/// Facts about this Mac used for the default display name and its illustration.
enum DeviceInfo {
    /// "Priya's MacBook Pro" from System Settings › General › Sharing.
    static func defaultDisplayName() -> String {
        Host.current().localizedName ?? "Mac"
    }

    /// Laptops report an internal battery; desktops do not.
    static var deviceKind: DeviceKind {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return .desktop }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType { return .laptop }
        }
        return .desktop
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
