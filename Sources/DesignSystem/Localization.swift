import Foundation
import SwiftUI

/// 国际化基础设施：从 DesignSystem 的 String Catalog（Localizable.xcstrings）解析当前语言的文案。
///
/// 现状：中文为源语言（sourceLanguage=zh-Hans），已内置 en 翻译作为起步。
/// 用法：把界面里的 `Text("智能扫描")` 逐步替换为 `Text(xLoc("智能扫描"))`，
/// 新字符串加进 Localizable.xcstrings 即可获得英文（及后续更多语言）。
/// 说明：SPM 各 target 的本地化资源在各自 Bundle.module，故用显式 bundle 查表。
public func xLoc(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: key, table: nil)
}

public extension Text {
    /// 本地化文案的便捷构造：`Text(localized: "智能扫描")`
    init(localized key: String) {
        self.init(xLoc(key))
    }
}
