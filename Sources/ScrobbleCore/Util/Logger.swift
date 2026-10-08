import os

/// Unified-logging categories. View with Console.app, filtering on
/// subsystem `com.scrobblekit`.
public enum Log {
    public static let capture = Logger(subsystem: "com.scrobblekit", category: "capture")
    public static let queue = Logger(subsystem: "com.scrobblekit", category: "queue")
    public static let auth = Logger(subsystem: "com.scrobblekit", category: "auth")
}
