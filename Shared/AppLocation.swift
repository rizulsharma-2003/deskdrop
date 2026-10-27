import Foundation

/// Where a copy of DeskDrop really is. macOS opens a downloaded app that's still
/// quarantined from a randomized, read-only copy of itself ("App Translocation"),
/// for example on a Mac where DeskDrop was first opened with Open Anyway. That
/// running location can't be replaced, so updates go to the original instead.
///
/// Security.framework has no public call for this; these are the private ones
/// Sparkle uses, looked up at run time, so if they're ever missing a copy simply
/// counts as not translocated.
enum AppLocation {
    /// The original location of `url` if it's inside a translocated copy, else `url`.
    static func original(of url: URL) -> URL {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) else { return url }
        defer { dlclose(security) }
        guard let isTranslocatedSymbol = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let originalPathSymbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return url }
        let isTranslocated = unsafeBitCast(isTranslocatedSymbol, to: IsTranslocatedURL.self)
        let originalPath = unsafeBitCast(originalPathSymbol, to: CreateOriginalPathForURL.self)

        var translocated = false
        guard isTranslocated(url as CFURL, &translocated, nil), translocated,
              let original = originalPath(url as CFURL, nil)?.takeRetainedValue() else { return url }
        return (original as URL).standardizedFileURL
    }

    private typealias IsTranslocatedURL = @convention(c)
        (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
    private typealias CreateOriginalPathForURL = @convention(c)
        (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
}
