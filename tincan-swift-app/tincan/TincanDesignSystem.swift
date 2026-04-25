import SwiftUI

enum TincanTone: CaseIterable {
    case mint
    case blue
    case amber
    case coral

    static func tone(for seed: String) -> TincanTone {
        let tones = Self.allCases
        let hash = abs(seed.hashValue)
        return tones[hash % tones.count]
    }

    var accent: Color {
        switch self {
        case .mint:
            return Color(red: 0.38, green: 0.95, blue: 0.72)
        case .blue:
            return Color(red: 0.43, green: 0.72, blue: 1.00)
        case .amber:
            return Color(red: 0.99, green: 0.80, blue: 0.36)
        case .coral:
            return Color(red: 0.98, green: 0.54, blue: 0.47)
        }
    }

    var tint: Color {
        accent.opacity(0.16)
    }
}

enum TincanPalette {
    static let canvasTop = Color(red: 0.09, green: 0.12, blue: 0.14)
    static let canvasBottom = Color(red: 0.03, green: 0.05, blue: 0.08)
    static let shell = Color(red: 0.05, green: 0.08, blue: 0.11)
    static let shellBorder = Color.white.opacity(0.10)
    static let panel = Color(red: 0.09, green: 0.13, blue: 0.17)
    static let panelRaised = Color(red: 0.12, green: 0.17, blue: 0.22)
    static let panelMuted = Color(red: 0.07, green: 0.10, blue: 0.14)
    static let textPrimary = Color(red: 0.92, green: 0.95, blue: 0.98)
    static let textSecondary = Color(red: 0.61, green: 0.69, blue: 0.76)
    static let textMuted = Color(red: 0.40, green: 0.47, blue: 0.54)
    static let textOnAccent = Color.black.opacity(0.84)
    static let divider = Color.white.opacity(0.08)
    static let callRed = Color(red: 0.77, green: 0.23, blue: 0.28)
    static let emerald500 = Color(red: 0.06, green: 0.73, blue: 0.51)
}

struct TincanCanvas<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [TincanPalette.canvasTop, TincanPalette.canvasBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color(red: 0.18, green: 0.34, blue: 0.28).opacity(0.18))
                .frame(width: 360, height: 360)
                .blur(radius: 110)
                .offset(x: -180, y: -320)

            content
        }
    }
}

struct TincanCardBackground: ViewModifier {
    let accent: Color?
    let cornerRadius: CGFloat
    let raised: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(raised ? TincanPalette.panelRaised.opacity(0.92) : TincanPalette.panel.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke((accent ?? TincanPalette.shellBorder).opacity(accent == nil ? 1 : 0.48), lineWidth: 1)
                    )
            )
    }
}

extension View {
    func tincanCard(accent: Color? = nil, cornerRadius: CGFloat = 24, raised: Bool = false) -> some View {
        modifier(TincanCardBackground(accent: accent, cornerRadius: cornerRadius, raised: raised))
    }
}

struct TincanToolbarButton: View {
    let label: String
    let systemImage: String
    let tone: Color
    var foreground: Color = TincanPalette.textPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .bold))
                Text(label)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                Capsule(style: .continuous)
                    .fill(tone)
            )
        }
        .buttonStyle(.plain)
    }
}

struct TincanIconButton: View {
    let systemImage: String
    let tone: Color
    var iconSize: CGFloat = 13
    var diameter: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .bold))
                .foregroundStyle(TincanPalette.textPrimary)
                .frame(width: diameter, height: diameter)
                .background(
                    Circle()
                        .fill(tone)
                )
        }
        .buttonStyle(.plain)
    }
}

struct TincanMiniControlButton: View {
    let systemImage: String
    let label: String
    let tone: Color
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isEnabled ? TincanPalette.textOnAccent : TincanPalette.textMuted)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(isEnabled ? tone : TincanPalette.panelRaised)
                    )
                    .shadow(color: isEnabled ? tone.opacity(0.26) : .clear, radius: 12, x: 0, y: 6)

                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(isEnabled ? tone : TincanPalette.textMuted)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.68)
    }
}

struct TincanMiniHeaderButton: View {
    let systemImage: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(TincanPalette.textPrimary.opacity(0.90))
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(destructive ? TincanPalette.callRed : TincanPalette.panel)
                )
        }
        .buttonStyle(.plain)
    }
}

struct TincanCapsuleTag: View {
    let text: String
    let tone: Color
    var filled = true

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(filled ? Color.black.opacity(0.84) : tone)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(filled ? tone : Color.clear)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tone.opacity(filled ? 0 : 0.8), lineWidth: filled ? 0 : 1)
            )
    }
}

struct TincanServerModeChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? Color.black.opacity(0.82) : TincanPalette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? TincanTone.mint.accent : TincanPalette.panelRaised)
                )
        }
        .buttonStyle(.plain)
    }
}

struct TincanSettingsSectionCard<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(TincanPalette.textPrimary)
            }

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(TincanPalette.textSecondary)
            }

            content
        }
        .padding(16)
        .tincanCard(cornerRadius: 24)
    }
}

enum TincanSettingsTypography {
    static let pageTitle = Font.system(size: 28, weight: .bold, design: .rounded)
    static let sectionTitle = Font.system(size: 18, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 14, weight: .regular, design: .rounded)
    static let caption = Font.system(size: 12, weight: .regular, design: .rounded)
    static let emphasis = Font.system(size: 14, weight: .semibold, design: .rounded)
    static let control = Font.system(size: 14, weight: .semibold, design: .rounded)
}

struct TincanSettingsSection<Content: View>: View {
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(TincanSettingsTypography.sectionTitle)
                    .foregroundStyle(TincanPalette.textPrimary)
            }

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(TincanSettingsTypography.body)
                    .foregroundStyle(TincanPalette.textSecondary)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TincanWaveStrip: View {
    let levels: [Double]
    let accent: Color
    private let dotSize: CGFloat = 9
    private let dotSpacing: CGFloat = 3
    private let dotCount = 17
    private let motionFrameInterval: TimeInterval = 1.0 / 18.0
    private let sweepCycleDuration: TimeInterval = 1.1

    var body: some View {
        TimelineView(.animation(minimumInterval: motionFrameInterval, paused: activityLevel <= 0.02)) { context in
            HStack(spacing: dotSpacing) {
                ForEach(0..<dotCount, id: \.self) { index in
                    Circle()
                        .fill(dotFillColor(for: index, timestamp: context.date.timeIntervalSinceReferenceDate))
                        .overlay(
                            Circle()
                                .stroke(
                                    dotStrokeColor(for: index, timestamp: context.date.timeIntervalSinceReferenceDate),
                                    lineWidth: 1
                                )
                        )
                        .frame(width: dotSize, height: dotSize)
                }
            }
            .frame(maxWidth: .infinity, minHeight: dotSize, maxHeight: dotSize)
            .padding(.vertical, 8)
            .animation(.easeOut(duration: 0.16), value: activityLevel)
        }
    }

    private var centerIndex: Int {
        dotCount / 2
    }

    private var activityLevel: Double {
        let recentLevels = Array(levels.suffix(4))
        guard !recentLevels.isEmpty else { return 0 }

        let peak = recentLevels.max() ?? 0
        let average = recentLevels.reduce(0.0, +) / Double(recentLevels.count)
        return max(0, min(1, peak * 0.7 + average * 0.3))
    }

    private func activation(for index: Int) -> Double {
        guard activityLevel > 0 else { return 0 }

        let distance = Double(abs(index - centerIndex))
        let reach = activityLevel * Double(centerIndex + 1)
        return max(0, min(1, reach - distance))
    }

    private func dotFillColor(for index: Int, timestamp: TimeInterval) -> Color {
        let dotActivation = activation(for: index)
        guard dotActivation > 0 else { return .clear }

        let distance = Double(abs(index - centerIndex))
        let normalizedDistance = centerIndex == 0 ? 0 : distance / Double(centerIndex)
        let intensity = 0.28
            + dotActivation * (0.42 + (1 - normalizedDistance) * 0.18)
            + shimmer(for: index, timestamp: timestamp)
            + sweepHighlight(for: index, timestamp: timestamp) * 0.08
        return accent.opacity(min(0.96, intensity))
    }

    private func dotStrokeColor(for index: Int, timestamp: TimeInterval) -> Color {
        let dotActivation = activation(for: index)
        if dotActivation > 0 {
            let intensity = 0.24
                + dotActivation * 0.36
                + sweepHighlight(for: index, timestamp: timestamp) * 0.4
            return accent.opacity(min(0.98, intensity))
        }

        return TincanPalette.shellBorder.opacity(0.85)
    }

    private func shimmer(for index: Int, timestamp: TimeInterval) -> Double {
        let dotActivation = activation(for: index)
        guard dotActivation > 0 else { return 0 }

        let phase = timestamp * 7.0 + Double(index) * 0.82
        let normalized = (sin(phase) + 1) * 0.5
        return normalized * 0.07 * dotActivation
    }

    private func sweepHighlight(for index: Int, timestamp: TimeInterval) -> Double {
        guard activityLevel > 0.04 else { return 0 }

        let distance = Double(abs(index - centerIndex))
        let reach = max(0.35, activityLevel * Double(centerIndex + 1) - 0.1)
        let phase = (timestamp / sweepCycleDuration).truncatingRemainder(dividingBy: 1)
        let normalizedTravel = phase <= 0.5 ? phase * 2 : (1 - phase) * 2
        let sweepPosition = normalizedTravel * reach
        let proximity = max(0, 1 - abs(distance - sweepPosition) / 1.35)
        return proximity * activation(for: index)
    }
}

func tincanTone(for conversation: TincanConversationSummary) -> TincanTone {
    TincanTone.tone(for: conversation.handle)
}

func shortDirectoryName(_ path: String) -> String {
    URL(fileURLWithPath: path).lastPathComponent
}

func relativeTimestampLabel(for date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}
