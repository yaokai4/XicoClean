import SwiftUI

/// Domain-neutral presentation tone. Feature modules map their sampling states to these tones.
public enum XSamplingTone: Sendable {
    case live
    case warming
    case attention
    case unavailable

    fileprivate var color: Color {
        switch self {
        case .live: return XColor.success
        case .warming: return XColor.auroraBlue
        case .attention: return XColor.warning
        case .unavailable: return XColor.textTertiary
        }
    }
}

/// A quiet, system-adaptive monitoring surface. Metric color belongs to data, never the card fill.
public struct XMonitoringSection<Content: View>: View {
    private let padding: CGFloat
    private let content: Content
    @Environment(\.displayScale) private var displayScale

    public init(padding: CGFloat = XSpacing.s, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(XColor.surface(at: .raised)))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(XColor.border, lineWidth: 1 / max(displayScale, 1)))
    }
}

public struct XSamplingStatusPill: View {
    private let text: String
    private let tone: XSamplingTone

    public init(_ text: String, tone: XSamplingTone) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        HStack(spacing: XSpacing.xs) {
            Circle().fill(tone.color).frame(width: 6, height: 6)
            Text(text).font(XFont.nano).lineLimit(1)
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tone.color.opacity(XAlpha.tint)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// A single-semantic-color gauge for a single metric.
public struct XSemanticGauge<Center: View>: View {
    private let fraction: Double
    private let color: Color
    private let size: CGFloat
    private let lineWidth: CGFloat
    private let center: Center

    public init(
        fraction: Double,
        color: Color,
        size: CGFloat = 60,
        lineWidth: CGFloat = 7,
        @ViewBuilder center: () -> Center
    ) {
        self.fraction = min(1, max(0, fraction))
        self.color = color
        self.size = size
        self.lineWidth = lineWidth
        self.center = center()
    }

    public var body: some View {
        ZStack {
            Circle().stroke(color.opacity(XAlpha.ghost), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center
        }
        .frame(width: size, height: size)
    }
}

public extension XSemanticGauge where Center == EmptyView {
    init(fraction: Double, color: Color, size: CGFloat = 60, lineWidth: CGFloat = 7) {
        self.init(fraction: fraction, color: color, size: size, lineWidth: lineWidth) { EmptyView() }
    }
}

public struct XAlignedValueColumn: View {
    private let label: String
    private let value: String
    private let emphasized: Bool
    private let alignment: HorizontalAlignment

    public init(
        label: String,
        value: String,
        emphasized: Bool = false,
        alignment: HorizontalAlignment = .trailing
    ) {
        self.label = label
        self.value = value
        self.emphasized = emphasized
        self.alignment = alignment
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(label).font(XFont.nano).foregroundStyle(XColor.textTertiary)
            Text(value)
                .font(emphasized ? XFont.captionEmphasis.monospacedDigit() : XFont.microMono)
                .foregroundStyle(emphasized ? XColor.textPrimary : XColor.textSecondary)
                .lineLimit(1)
        }
    }
}
