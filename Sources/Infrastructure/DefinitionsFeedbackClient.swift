import Foundation

// MARK: - 安全库误报上报（docs/14 P5）
// 「报告误报」右键动作的传输层：匿名上报规则 id 与模块名——**绝不包含用户路径、文件名或
// 任何本机内容**（隐私即卖点铁律）。Fire-and-forget：失败静默（本地忽略清单已即时生效，
// 上报只是帮助规则库改进，不阻塞用户操作）。
// 服务端路由：POST <activationBase>/api/definitions/feedback（与激活同源，服务器侧待上线）。

public enum DefinitionsFeedbackClient {
    public static func reportFalsePositive(ruleID: String, module: String) {
        var url = LicenseService.activationBaseURL()
        url.appendPathComponent("api/definitions/feedback")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "ruleId": ruleID,
            "module": module,
            "kind": "false_positive",
        ])
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        URLSession(configuration: config).dataTask(with: req).resume()
    }
}
