import Foundation
import Shared

/// 特权助手守护进程（以 root 运行；需正式签名 + SMAppService 注册后才会被系统拉起）。
/// 只暴露白名单化、参数化的高危操作，并在执行前再次做安全校验（纵深防御，不信任客户端）。
final class HelperService: NSObject, XicoHelperProtocol, NSXPCListenerDelegate {

    // 助手端独立维护的保护清单（绝不删除）
    private let protectedPrefixes = ["/System", "/usr", "/bin", "/sbin", "/Library/Apple", "/private/var/db"]

    func version(reply: @escaping (String) -> Void) {
        reply("0.1.0")
    }

    func runMaintenance(_ rawTask: String, reply: @escaping (Bool, String?) -> Void) {
        guard let task = MaintenanceTask(rawValue: rawTask) else {
            reply(false, "未知任务"); return
        }
        let (cmd, args): (String, [String])
        switch task {
        case .freeMemory:          (cmd, args) = ("/usr/sbin/purge", [])
        case .flushDNS:            (cmd, args) = ("/usr/bin/dscacheutil", ["-flushcache"])
        case .rebuildSpotlight:    (cmd, args) = ("/usr/bin/mdutil", ["-E", "/"])
        case .runPeriodicScripts:  (cmd, args) = ("/usr/sbin/periodic", ["daily", "weekly", "monthly"])
        case .deleteLocalSnapshots:(cmd, args) = ("/usr/bin/tmutil", ["deletelocalsnapshots", "/"])
        }
        let (ok, output) = Self.run(cmd, args)
        reply(ok, output)
    }

    func removeProtected(paths: [String], reply: @escaping (Int64, [String]) -> Void) {
        var freed: Int64 = 0
        var failures: [String] = []
        let fm = FileManager.default
        for path in paths {
            let std = (path as NSString).standardizingPath
            if std == "/" || protectedPrefixes.contains(where: { std == $0 || std.hasPrefix($0 + "/") }) {
                failures.append(path); continue
            }
            let url = URL(fileURLWithPath: std)
            let size = (try? fm.attributesOfItem(atPath: std)[.size] as? Int64) ?? 0
            do { try fm.removeItem(at: url); freed += size }
            catch { failures.append(path) }
        }
        reply(freed, failures)
    }

    // MARK: XPC 连接校验（生产中应校验调用方代码签名 / Team ID）
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        // TODO(生产): 用 conn.auditToken + SecCodeCopyGuestWithAttributes 校验调用方是同 Team ID 的 Xico
        conn.exportedInterface = NSXPCInterface(with: XicoHelperProtocol.self)
        conn.exportedObject = self
        conn.resume()
        return true
    }

    static func run(_ path: String, _ args: [String]) -> (Bool, String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)
            return (proc.terminationStatus == 0, out)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

let delegate = HelperService()
let listener = NSXPCListener(machServiceName: XicoHelperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
