import Foundation
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
        content.title = "清理完成"
        content.body = "已释放 \(reclaimed) · 清理 \(count) 项"
        content.sound = nil
        let req = UNNotificationRequest(identifier: "xico.clean.done", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
