import Foundation
import DesignSystem
@preconcurrency import UserNotifications

/// 系统通知：长任务（清理）完成后即使窗口在后台也能让用户知道。
/// 首次使用时请求授权；被拒则静默跳过（不打扰）。
public enum Notifier {
    public static func notifyCleaningDone(reclaimed: String, count: Int) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                post(reclaimed: reclaimed, count: count)
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
                    if granted { post(reclaimed: reclaimed, count: count) }
                }
            default:
                break   // 用户已拒绝：不打扰
            }
        }
    }

    private static func post(reclaimed: String, count: Int) {
        let content = UNMutableNotificationContent()
        content.title = xLoc("清理完成")
        content.body = xLocF("已释放 %@ · 清理 %d 项", reclaimed, count)
        content.sound = nil
        let req = UNNotificationRequest(identifier: "xico.clean.done", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// 废纸篓哨兵通知（P4）：删 App 入废纸篓时提示其残留。identifier 前缀
    /// `xico.sentinel.` 供 AppDelegate 的通知点击路由识别（直达卸载器）。
    public static func notifySentinel(appName: String, count: Int, bytes: String, bundleID: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let fire: @Sendable () -> Void = {
                let content = UNMutableNotificationContent()
                content.title = xLocF("检测到删除 %@", appName)
                content.body = xLocF("本机还留有 %d 项残留（%@）。点按打开卸载器清理。", count, bytes)
                content.sound = nil
                let req = UNNotificationRequest(identifier: "xico.sentinel.\(bundleID)",
                                                content: content, trigger: nil)
                UNUserNotificationCenter.current().add(req)
            }
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                fire()
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
                    if granted { fire() }
                }
            default:
                break   // 用户已拒绝：不打扰
            }
        }
    }

    /// 监控阈值告警通知（如「CPU 持续高于 90%」）。identifier 用于同一规则去重。
    public static func notifyAlert(title: String, body: String, identifier: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                postAlert(title: title, body: body, identifier: identifier)
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { postAlert(title: title, body: body, identifier: identifier) }
                }
            default:
                break
            }
        }
    }

    private static func postAlert(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
