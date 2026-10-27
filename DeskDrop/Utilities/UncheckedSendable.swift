/// Carries a value across an isolation boundary when the value is known to be safe
/// to share but lacks a `Sendable` annotation — for example Multipeer Connectivity
/// objects handed to delegate callbacks on a private queue and immediately passed
/// to the main actor, or Foundation's thread-safe `Progress`.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
