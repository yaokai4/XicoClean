import Foundation
import Domain
import Infrastructure
import DesignSystem

public enum ApplicationUsageFocus: Equatable, Sendable {
    case cpu
    case memory
}

public struct ApplicationUsageRowPresentation: Equatable, Sendable {
    public let primaryText: String
    public let secondaryText: String
    public let fillFraction: Double

    public static func make(
        usage: ApplicationUsage,
        focus: ApplicationUsageFocus,
        cpuMode: CPUDisplayMode,
        memoryStyle: MemoryUnitStyle,
        largestMemory: Int64 = 1
    ) -> Self {
        let cpu = usage.cpuPercent(mode: cpuMode)
        let cpuText = cpu.map { String(format: "%.1f%%", $0) } ?? xLoc("采样中")
        let memoryText = usage.physicalFootprintBytes.formattedMemory(style: memoryStyle)
        let unboundedFill: Double
        switch focus {
        case .cpu:
            let maximum = cpuMode == .normalized
                ? 100
                : 100 * Double(ProcessInfo.processInfo.activeProcessorCount)
            unboundedFill = (cpu ?? 0) / maximum
        case .memory:
            unboundedFill = Double(usage.physicalFootprintBytes) / Double(max(1, largestMemory))
        }
        let fill = min(1, max(0, unboundedFill))

        switch focus {
        case .cpu:
            return Self(primaryText: cpuText, secondaryText: memoryText, fillFraction: fill)
        case .memory:
            return Self(primaryText: memoryText, secondaryText: cpuText, fillFraction: fill)
        }
    }
}
