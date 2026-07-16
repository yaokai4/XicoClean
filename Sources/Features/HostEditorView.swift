import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Domain
import Infrastructure
import DesignSystem

/// 添加 / 编辑主机表单。机密（密码/私钥）经 ViewModel 存 Keychain，绝不落 JSON。
struct HostEditorView: View {
    @ObservedObject var vm: ServersViewModel
    let editing: ServerHost?
    let onClose: () -> Void

    @State private var name: String
    @State private var hostname: String
    @State private var port: String
    @State private var username: String
    @State private var authKind: SSHAuthKind
    @State private var password: String = ""
    @State private var privateKeyPEM: String = ""
    @State private var passphrase: String = ""
    @State private var colorIndex: Int
    @State private var symbol: String
    @State private var pollInterval: Double
    @State private var jumpHostID: UUID?
    @State private var keyDropActive = false
    @State private var keyImportNote: String?

    private let hasStoredPassword: Bool
    private let hasStoredKey: Bool

    init(vm: ServersViewModel, editing: ServerHost?, onClose: @escaping () -> Void) {
        self.vm = vm
        self.editing = editing
        self.onClose = onClose
        _name = State(initialValue: editing?.name ?? "")
        _hostname = State(initialValue: editing?.hostname ?? "")
        _port = State(initialValue: String(editing?.port ?? 22))
        _username = State(initialValue: editing?.username ?? "")
        _authKind = State(initialValue: editing?.authKind ?? .password)
        _colorIndex = State(initialValue: editing?.colorIndex ?? 0)
        _symbol = State(initialValue: editing?.symbol ?? "server.rack")
        _pollInterval = State(initialValue: editing?.pollInterval ?? 3)
        _jumpHostID = State(initialValue: editing?.jumpHostID)
        hasStoredPassword = editing.map { vm.hasStoredPassword($0) } ?? false
        hasStoredKey = editing.map { vm.hasStoredKey($0) } ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editing == nil ? xLoc("添加主机") : xLoc("编辑主机")).font(XFont.title2)
                Spacer()
            }
            .padding(XSpacing.xl)
            Divider().opacity(0.3)

            ScrollView {
                VStack(alignment: .leading, spacing: XSpacing.l) {
                    field(xLoc("名称"), placeholder: xLoc("如：生产 Web"), text: $name)
                    HStack(spacing: XSpacing.m) {
                        VStack(alignment: .leading, spacing: XSpacing.xs) {
                            label(xLoc("主机地址"))
                            XCapsuleTextField(placeholder: "example.com / 10.0.0.5", text: $hostname)
                        }
                        VStack(alignment: .leading, spacing: XSpacing.xs) {
                            label(xLoc("端口"))
                            XCapsuleTextField(placeholder: "22", text: $port).frame(width: 88)
                        }
                    }
                    field(xLoc("用户名"), placeholder: "root / ubuntu", text: $username)

                    VStack(alignment: .leading, spacing: XSpacing.xs) {
                        label(xLoc("鉴权方式"))
                        XSegmentedControl(selection: $authKind, options: [SSHAuthKind.password, .privateKey].map {
                            .init(tag: $0, label: xLoc($0.label), a11y: xLoc($0.label))
                        })
                    }

                    if authKind == .password {
                        VStack(alignment: .leading, spacing: XSpacing.xs) {
                            label(xLoc("密码"))
                            SecureField(hasStoredPassword ? xLoc("已保存 · 留空则不修改") : xLoc("SSH 密码"), text: $password)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, XSpacing.m).padding(.vertical, XSpacing.s)
                                .background(XColor.surfaceAlt.opacity(0.8), in: Capsule())
                                .overlay(Capsule().strokeBorder(XColor.border))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: XSpacing.xs) {
                            HStack(alignment: .firstTextBaseline) {
                                label(xLoc("私钥（.pem / OpenSSH · RSA / ed25519）"))
                                Spacer()
                                Button { importKeyFile() } label: {
                                    Label(xLoc("从文件导入…"), systemImage: "doc.badge.plus")
                                        .font(XFont.micro)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(XColor.brand)
                                .help(xLoc("选择一个 .pem / id_rsa / id_ed25519 私钥文件"))
                            }
                            ZStack {
                                TextEditor(text: $privateKeyPEM)
                                    .font(XFont.captionMono).frame(height: 110)
                                    .padding(XSpacing.s)
                                    .scrollContentBackground(.hidden)
                                    .background(XColor.surfaceAlt.opacity(0.6), in: RoundedRectangle(cornerRadius: XRadius.control))
                                    .overlay(RoundedRectangle(cornerRadius: XRadius.control)
                                        .strokeBorder(keyDropActive ? XColor.brand : XColor.border, lineWidth: keyDropActive ? 2 : 1))
                                if privateKeyPEM.isEmpty {
                                    Text(xLoc("粘贴私钥内容，或把 .pem 文件拖到这里"))
                                        .font(XFont.captionMono).foregroundStyle(XColor.textTertiary)
                                        .allowsHitTesting(false)
                                        .padding(.horizontal, XSpacing.m)
                                }
                            }
                            // 拖放 .pem / 私钥文件到编辑框即导入。
                            .onDrop(of: [.fileURL], isTargeted: $keyDropActive) { providers in
                                loadDroppedKey(providers); return true
                            }
                            if let note = keyImportNote {
                                Text(note).font(XFont.micro).foregroundStyle(XColor.success)
                            } else if hasStoredKey && privateKeyPEM.isEmpty {
                                Text(xLoc("已保存私钥 · 留空则不修改")).font(XFont.micro).foregroundStyle(XColor.textTertiary)
                            }
                            SecureField(xLoc("私钥口令（可选，密钥加密时填写）"), text: $passphrase)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, XSpacing.m).padding(.vertical, XSpacing.s)
                                .background(XColor.surfaceAlt.opacity(0.8), in: Capsule())
                                .overlay(Capsule().strokeBorder(XColor.border))
                        }
                    }

                    // 跳板机 ProxyJump（ServerCat 没有）：经堡垒机到达内网主机。
                    let jumpCandidates = vm.hosts.filter { $0.id != editing?.id }
                    if !jumpCandidates.isEmpty {
                        VStack(alignment: .leading, spacing: XSpacing.xs) {
                            label(xLoc("跳板机（可选）"))
                            Picker("", selection: $jumpHostID) {
                                Text(xLoc("直连（不经跳板）")).tag(UUID?.none)
                                ForEach(jumpCandidates) { h in
                                    Text("\(h.name) · \(h.endpointLabel)").tag(UUID?.some(h.id))
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }

                    VStack(alignment: .leading, spacing: XSpacing.xs) {
                        label(xLoc("图标与颜色"))
                        HStack(spacing: XSpacing.s) {
                            ForEach(Array(ServerPalette.symbols.enumerated()), id: \.offset) { _, sym in
                                Button { symbol = sym } label: {
                                    Image(systemName: sym).font(.system(size: 15))
                                        .frame(width: 30, height: 30)
                                        .foregroundStyle(symbol == sym ? XColor.onAccent : XColor.textSecondary)
                                        .background(symbol == sym ? AnyShapeStyle(XColor.brand) : AnyShapeStyle(XColor.surfaceAlt),
                                                    in: RoundedRectangle(cornerRadius: XRadius.control))
                                }.buttonStyle(.plain)
                            }
                        }
                        HStack(spacing: XSpacing.s) {
                            ForEach(0..<ServerPalette.options.count, id: \.self) { i in
                                Button { colorIndex = i } label: {
                                    Circle().fill(LinearGradient(colors: ServerPalette.colors(i), startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 24, height: 24)
                                        .overlay(Circle().strokeBorder(XColor.textPrimary, lineWidth: colorIndex == i ? 2 : 0))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(XSpacing.xl)
            }

            Divider().opacity(0.3)
            HStack {
                Spacer()
                Button(xLoc("取消"), action: onClose).buttonStyle(XSecondaryButtonStyle())
                Button(xLoc("保存"), action: save).buttonStyle(XPrimaryButtonStyle()).disabled(!isValid)
            }
            .padding(XSpacing.xl)
        }
        .frame(width: 520, height: 620)
    }

    private var isValid: Bool {
        SSHInputValidator.isValidHostname(hostname) &&
        SSHInputValidator.isValidUsername(username) &&
        Int(port).map(SSHInputValidator.isValidPort) == true
    }

    private func save() {
        let cleanHostname = SSHInputValidator.normalizedHostname(hostname)
        let cleanUsername = SSHInputValidator.normalizedUsername(username)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = cleanName.isEmpty ? cleanHostname : cleanName
        var host = editing ?? ServerHost(name: resolvedName, hostname: cleanHostname, username: cleanUsername)
        host.name = resolvedName
        host.hostname = cleanHostname
        host.port = Int(port) ?? 22
        host.username = cleanUsername
        host.authKind = authKind
        host.symbol = symbol
        host.colorIndex = colorIndex
        host.pollInterval = pollInterval
        host.jumpHostID = jumpHostID
        vm.saveHost(host,
                    password: authKind == .password ? password : nil,
                    privateKeyPEM: authKind == .privateKey ? privateKeyPEM : nil,
                    passphrase: authKind == .privateKey ? passphrase : nil)
        onClose()
    }

    // MARK: 私钥文件导入（.pem / id_rsa / id_ed25519）

    private func importKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = xLoc("选择私钥文件")
        panel.message = xLoc("支持 AWS/Lightsail .pem、id_rsa、id_ed25519 等私钥文件")
        // .pem 有官方 UTType；私钥文件常无扩展名，故也允许「无扩展名」与纯数据。
        panel.allowedContentTypes = [UTType(filenameExtension: "pem") ?? .data, .data, .text, .item]
        panel.allowsOtherFileTypes = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadKey(from: url)
    }

    private func loadDroppedKey(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { loadKey(from: url) }
        }
    }

    private func loadKey(from url: URL) {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            keyImportNote = nil
            vm.toast = xLoc("无法读取该文件（可能不是文本格式的私钥）")
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("PRIVATE KEY") else {
            keyImportNote = nil
            vm.toast = xLoc("该文件不像私钥（缺少 PRIVATE KEY 头）。请选择 .pem / id_rsa / id_ed25519")
            return
        }
        privateKeyPEM = trimmed
        keyImportNote = xLocF("已从 %@ 导入私钥", url.lastPathComponent)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(XFont.micro).foregroundStyle(XColor.textTertiary)
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: XSpacing.xs) {
            label(title)
            XCapsuleTextField(placeholder: placeholder, text: text)
        }
    }
}
