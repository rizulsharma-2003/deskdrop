import AppKit
import Network

/// Local-network privacy helpers.
///
/// macOS has no API to ask whether the user allowed local-network access. A Bonjour
/// browse for DeskDrop's own service reports `PolicyDenied` when access is blocked,
/// so this probe watches for that and for the permission being granted later.
@MainActor
final class LocalNetworkPermissionProbe {
    private var browser: NWBrowser?
    var onChange: ((_ denied: Bool) -> Void)?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_\(PeerConnectionService.serviceType)._tcp", domain: nil),
                                using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            let denied: Bool?
            switch state {
            case .waiting(let error), .failed(let error):
                denied = NetworkPermissions.isPolicyDenied(error) ? true : nil
            case .ready:
                denied = false
            default:
                denied = nil
            }
            guard let denied else { return }
            MainActor.assumeIsolated {
                self?.onChange?(denied)
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// Watches whether any network interface is usable, so DeskDrop can say so instead
/// of appearing to search forever, and restart discovery when the network changes.
@MainActor
final class NetworkPathObserver {
    private var monitor: NWPathMonitor?
    var onChange: ((_ isAvailable: Bool, _ interfaces: [String]) -> Void)?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let interfaces = path.availableInterfaces.map(\.name).sorted()
            MainActor.assumeIsolated {
                self?.onChange?(available, interfaces)
            }
        }
        self.monitor = monitor
        monitor.start(queue: .main)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}

enum NetworkPermissions {
    /// kDNSServiceErr_PolicyDenied: the user has not allowed local-network access.
    static let policyDeniedCode: Int = -65570
    /// NSNetServicesMissingRequiredConfigurationError: Info.plist lacks NSBonjourServices.
    static let missingConfigurationCode: Int = -72008

    static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return Int(code) == policyDeniedCode }
        return false
    }

    static func isPolicyDenied(_ error: Error) -> Bool {
        errorCodes(error).contains(policyDeniedCode)
    }

    static func isMisconfigured(_ error: Error) -> Bool {
        errorCodes(error).contains(missingConfigurationCode)
    }

    private static func errorCodes(_ error: Error) -> [Int] {
        let nsError = error as NSError
        var codes = [nsError.code]
        if let netServicesCode = nsError.userInfo["NSNetServicesErrorCode"] as? Int { codes.append(netServicesCode) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError { codes.append(underlying.code) }
        return codes
    }

    /// Opens System Settings › Privacy & Security › Local Network.
    static func openLocalNetworkSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }
}
