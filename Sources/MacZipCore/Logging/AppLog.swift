import Foundation
import os

/// 统一 os_log 门面:调试日志默认不持久化,避免生产环境噪声。
public enum AppLog {
    public enum Category: String {
        case app
        case core
        case ext
        case quicklook
    }

    private static let subsystem = MacZipConstants.appBundleIdentifier

    private static func logger(for category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    public static func info(_ message: String, category: Category = .core) {
        logger(for: category).info("\(message, privacy: .public)")
    }

    public static func debug(_ message: String, category: Category = .core) {
        logger(for: category).debug("\(message, privacy: .public)")
    }

    public static func error(_ message: String, category: Category = .core) {
        logger(for: category).error("\(message, privacy: .public)")
    }
}
