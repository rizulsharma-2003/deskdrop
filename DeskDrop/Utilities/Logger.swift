import os

/// Structured, privacy-aware loggers. File names and peer names are logged with
/// `.private` so they are redacted from logs collected outside a debug session.
enum Log {
    static let subsystem = "com.deskdrop.app"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let connection = Logger(subsystem: subsystem, category: "connection")
    static let transfer = Logger(subsystem: subsystem, category: "transfer")
    static let files = Logger(subsystem: subsystem, category: "files")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}
