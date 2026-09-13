import Foundation

/// MacZip 全局常量：Bundle 标识、App Group、分布式通知名。
/// 主 App / Finder 扩展 / QuickLook 扩展三个进程共用，必须保持单一定义源。
public enum MacZipConstants {
    public static let appBundleIdentifier = "wzl.MacZip"
    public static let extensionBundleIdentifier = "wzl.MacZip.Extension"
    public static let quickLookBundleIdentifier = "wzl.MacZip.QuickLook"
    public static let appGroupIdentifier = "group.wzl.MacZip"
    public static let appName = "MacZip"

    /// Extension → 主 App 的动作触发信号（分布式空信号，无 userInfo）。
    public static let triggerActionSignal = Notification.Name("wzl.MacZip.triggerActionSignal")
    /// 主 App → Extension 的配置变更信号。
    public static let configChangedSignal = Notification.Name("wzl.MacZip.configChanged")
}
