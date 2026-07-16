import SwiftUI
import Domain
import Infrastructure
import DesignSystem

/// 服务器阈值告警设置——ServerCat 完全没有。规则全局生效，持续超阈后发系统推送。
struct ServerAlertsView: View {
    @ObservedObject var vm: ServersViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(xLoc("告警与推送")).font(XFont.title2)
                    Text(xLoc("持续超过阈值时发送系统通知 · ServerCat 没有的能力")).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                }
                Spacer()
            }
            .padding(XSpacing.xl)
            Divider().opacity(0.3)

            ScrollView {
                VStack(spacing: XSpacing.m) {
                    ForEach($vm.alertRules) { $rule in
                        ruleRow($rule)
                    }
                    Divider().opacity(0.3).padding(.vertical, XSpacing.xs)
                    HStack(spacing: XSpacing.m) {
                        Toggle(isOn: $vm.hostDownAlerts) { EmptyView() }
                            .toggleStyle(XThemeSwitchStyle()).labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(xLoc("主机掉线通知")).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                            Text(xLoc("连接断开或采样连续失败时提醒")).font(XFont.micro).foregroundStyle(XColor.textTertiary)
                        }
                        Spacer()
                        Image(systemName: "bolt.slash.fill").foregroundStyle(XColor.danger)
                    }
                    .padding(XSpacing.m)
                    .background(XColor.surfaceAlt.opacity(0.5), in: RoundedRectangle(cornerRadius: XRadius.card, style: .continuous))
                }
                .padding(XSpacing.xl)
            }

            Divider().opacity(0.3)
            HStack {
                Text(xLocF("%d 条规则已启用", vm.enabledAlertCount)).font(XFont.caption).foregroundStyle(XColor.textTertiary)
                Spacer()
                Button(xLoc("完成")) { vm.saveAlerts(); onClose() }.buttonStyle(XPrimaryButtonStyle())
            }
            .padding(XSpacing.xl)
        }
        .frame(width: 500, height: 520)
    }

    private func ruleRow(_ rule: Binding<ServerAlertRule>) -> some View {
        let r = rule.wrappedValue
        return VStack(spacing: XSpacing.s) {
            HStack(spacing: XSpacing.m) {
                Toggle(isOn: rule.enabled) { EmptyView() }
                    .toggleStyle(XThemeSwitchStyle()).labelsHidden()
                Image(systemName: iconFor(r.metric)).font(.system(size: 14)).foregroundStyle(colorFor(r.metric))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(xLoc(r.metric.title)).font(XFont.bodyEmphasis).foregroundStyle(XColor.textPrimary)
                    Text(xLocF("持续 %d 次采样", r.sustainedSamples)).font(XFont.micro).foregroundStyle(XColor.textTertiary)
                }
                Spacer()
                Text(r.thresholdText).font(XFont.monoMini).foregroundStyle(colorFor(r.metric))
            }
            if r.metric.isFraction {
                Slider(value: rule.threshold, in: 0.5...0.99, step: 0.01).tint(colorFor(r.metric))
                    .disabled(!r.enabled)
            } else {
                Stepper(value: rule.threshold, in: 1...64, step: 1) {
                    Text(xLocF("阈值 %.0f", r.threshold)).font(XFont.caption).foregroundStyle(XColor.textSecondary)
                }.disabled(!r.enabled)
            }
        }
        .padding(XSpacing.m)
        .background(XColor.surfaceAlt.opacity(0.5), in: RoundedRectangle(cornerRadius: XRadius.card, style: .continuous))
        .opacity(r.enabled ? 1 : 0.6)
    }

    private func iconFor(_ m: ServerAlertMetric) -> String {
        switch m { case .cpu: return "cpu"; case .memory: return "memorychip"; case .disk: return "internaldrive"; case .load1: return "gauge.with.dots.needle.bottom.50percent" }
    }
    private func colorFor(_ m: ServerAlertMetric) -> Color {
        switch m {
        case .cpu: return XColor.metricCPU.first ?? XColor.brand
        case .memory: return XColor.metricMemory.first ?? XColor.brand
        case .disk: return XColor.metricDisk.first ?? XColor.brand
        case .load1: return XColor.warning
        }
    }
}
