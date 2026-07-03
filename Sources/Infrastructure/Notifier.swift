import Foundation
import DesignSystem
import UserNotifications

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

    /// 监控阈值告警通知（如「CPU 持续高于 90%」）。identifier 用于同一规则去重。
    public static func notifyAlert(title: String, body: String, identifier: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                postAlert(title: title, body: body, identifier: identifier)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
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
