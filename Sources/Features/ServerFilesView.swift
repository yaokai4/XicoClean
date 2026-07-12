import SwiftUI
import Domain
import Infrastructure
import DesignSystem
import UniformTypeIdentifiers

/// SFTP 文件浏览器面板：面包屑路径 + 目录列表 + 下载(→下载文件夹) / 上传 / 删除 / 新建文件夹。
/// 走一条独立 SSH 连接，进入「文件」标签时按需连接。
@MainActor
final class ServerFilesModel: ObservableObject {
    @Published var components: [String] = []       // 相对 home 的路径栈
    @Published var entries: [SFTPEntry] = []
    @Published var loading = false
    @Published var connected = false
    @Published var error: String?
    @Published var busyName: String?

    private let host: ServerHost
    private let credential: SSHCredential?
    private var browser: SFTPBrowser?
    private var stopped = false

    init(host: ServerHost, credential: SSHCredential?) {
        self.host = host
        self.credential = credential
    }

    var displayPath: String { "~/" + components.joined(separator: "/") }
    private var queryPath: String { components.isEmpty ? "." : "./" + components.joined(separator: "/") }

    func start() async {
        guard browser == nil else { return }
        guard let cred = credential else { error = xLoc("缺少凭据：请先在主机设置中填写密码或私钥"); return }
        loading = true; error = nil
        let b = SFTPBrowser(host: host)
        do {
            try await b.connect(credential: cred)
            // 连接过程中若已离开该标签（stop 先跑），关掉这条刚建立的连接，避免泄漏。
            if stopped { await b.disconnect(); return }
            browser = b
            connected = true
            await reload()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        loading = false
    }

    func stop() async {
        stopped = true
        let b = browser; browser = nil; connected = false
        await b?.disconnect()
    }

    func reload() async {
        guard let b = browser else { return }
        loading = true; error = nil
        do { entries = try await b.list(queryPath) }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        loading = false
    }

    func open(_ entry: SFTPEntry) async {
        guard entry.isDirectory else { return }
        components.append(entry.name)
        await reload()
    }

    func goUp() async {
        guard !components.isEmpty else { return }
        components.removeLast()
        await reload()
    }

    func goRoot() async { components.removeAll(); await reload() }

    func download(_ entry: SFTPEntry) async {
        guard let b = browser, !entry.isDirectory else { return }
        busyName = entry.name
        let remote = queryPath + "/" + entry.name
        let dest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads").appendingPathComponent(entry.name)
        do { try await b.download(remotePath: remote, to: dest); error = nil }
        catch { self.error = xLocF("下载失败：%@", (error as? LocalizedError)?.errorDescription ?? "\(error)") }
        busyName = nil
    }

    func delete(_ entry: SFTPEntry) async {
        guard let b = browser else { return }
        let remote = queryPath + "/" + entry.name
        do { try await b.remove(remote); await reload() }
        catch { self.error = xLocF("删除失败：%@", (error as? LocalizedError)?.errorDescription ?? "\(error)") }
    }

    func upload(_ localURL: URL) async {
        guard let b = browser else { return }
        let remote = queryPath + "/" + localURL.lastPathComponent
        busyName = localURL.lastPathComponent
        do { try await b.upload(localURL: localURL, toRemotePath: remote); await reload() }
        catch { self.error = xLocF("上传失败：%@", (error as? LocalizedError)?.errorDescription ?? "\(error)") }
        busyName = nil
    }
}

struct ServerFilesView: View {
    let host: ServerHost
    let credential: SSHCredential?
    @StateObject private var model: ServerFilesModel

    init(host: ServerHost, credential: SSHCredential?) {
        self.host = host
        self.credential = credential
        _model = StateObject(wrappedValue: ServerFilesModel(host: host, credential: credential))
    }

    var body: some View {
        VStack(spacing: XSpacing.s) {
            // 面包屑 + 操作
            HStack(spacing: XSpacing.s) {
                Button { Task { await model.goUp() } } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(XSecondaryButtonStyle()).disabled(model.components.isEmpty || !model.connected)
                Button { Task { await model.goRoot() } } label: { Image(systemName: "house") }
                    .buttonStyle(XSecondaryButtonStyle()).disabled(!model.connected)
                Text(model.displayPath).font(XFont.captionMono).foregroundStyle(XColor.textSecondary).lineLimit(1)
                Spacer()
                if model.loading { XSpinner(size: 14) }
                Button { uploadPanel() } label: { Image(systemName: "arrow.up.doc") }
                    .buttonStyle(XSecondaryButtonStyle()).disabled(!model.connected).help(xLoc("上传文件"))
                Button { Task { await model.reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(XSecondaryButtonStyle()).disabled(!model.connected)
            }

            if let err = model.error {
                Text(err).font(XFont.caption).foregroundStyle(XColor.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !model.connected && !model.loading && model.error == nil {
                XEmptyState(systemImage: "folder.badge.questionmark", title: xLoc("正在连接 SFTP…"), subtitle: "")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.entries) { entry in
                            fileRow(entry)
                        }
                        if model.entries.isEmpty && model.connected && !model.loading {
                            Text(xLoc("空目录")).font(XFont.caption).foregroundStyle(XColor.textTertiary).padding(.vertical, XSpacing.l)
                        }
                    }
                }
            }
        }
        .padding(XSpacing.xl)
        .task { await model.start() }
        .onDisappear { Task { await model.stop() } }
    }

    private func fileRow(_ entry: SFTPEntry) -> some View {
        HStack(spacing: XSpacing.m) {
            Image(systemName: entry.isDirectory ? "folder.fill" : (entry.isSymlink ? "arrow.uturn.right.circle" : "doc"))
                .font(.system(size: 14))
                .foregroundStyle(entry.isDirectory ? XColor.brand : XColor.textSecondary)
                .frame(width: 20)
            Text(entry.name).font(XFont.captionMono).foregroundStyle(XColor.textPrimary).lineLimit(1)
            Spacer()
            if model.busyName == entry.name { XSpinner(size: 12) }
            if !entry.isDirectory {
                Text(SrvFmt.bytes(entry.size)).font(XFont.micro).foregroundStyle(XColor.textTertiary)
            }
            Text(entry.permissions).font(XFont.micro).foregroundStyle(XColor.textTertiary).frame(width: 78, alignment: .leading)
            if !entry.isDirectory {
                Button { Task { await model.download(entry) } } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.plain).foregroundStyle(XColor.brand).help(xLoc("下载到「下载」文件夹"))
            }
            Menu {
                if !entry.isDirectory { Button(xLoc("下载")) { Task { await model.download(entry) } } }
                Button(xLoc("删除"), role: .destructive) { Task { await model.delete(entry) } }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
        }
        .padding(.vertical, 5).padding(.horizontal, XSpacing.s)
        .contentShape(Rectangle())
        .onTapGesture { if entry.isDirectory { Task { await model.open(entry) } } }
        .background(XColor.surface, in: RoundedRectangle(cornerRadius: XRadius.control, style: .continuous))
    }

    private func uploadPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.upload(url) }
        }
    }
}
