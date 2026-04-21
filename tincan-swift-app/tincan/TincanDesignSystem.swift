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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(TincanPalette.textPrimary)
                .frame(width: 40, height: 40)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(tone)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(TincanPalette.panel)
                            .overlay(
                                Circle()
                                    .stroke(tone.opacity(0.28), lineWidth: 1)
                            )
                    )

                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(TincanPalette.textMuted)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
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
                .font(.system(size: 11, weight: .bold, design: .monospaced))
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
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(TincanPalette.textPrimary)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(TincanPalette.textMuted)
            }

            content
        }
        .padding(16)
        .tincanCard(cornerRadius: 24)
    }
}

struct TincanWaveStrip: View {
    let levels: [Double]
    let accent: Color
    private let barWidth: CGFloat = 4
    private let barCount = 14

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(displayedLevels.enumerated()), id: \.offset) { index, level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(barColor(for: level, index: index))
                    .frame(width: barWidth, height: barHeight(for: level))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.14), value: displayedLevels)
    }

    private var displayedLevels: [Double] {
        let clippedLevels = Array(levels.suffix(barCount))
        if clippedLevels.count == barCount {
            return clippedLevels
        }
        return Array(repeating: 0.0, count: barCount - clippedLevels.count) + clippedLevels
    }

    private func barHeight(for level: Double) -> CGFloat {
        let normalizedLevel = max(0, min(1, level))
        let minHeight: CGFloat = 8
        let maxHeight: CGFloat = 34
        return minHeight + CGFloat(pow(normalizedLevel, 0.75)) * (maxHeight - minHeight)
    }

    private func barColor(for level: Double, index: Int) -> Color {
        let normalizedLevel = max(0, min(1, level))
        let restingOpacity = index < 4 ? 0.28 : 0.14
        return accent.opacity(restingOpacity + normalizedLevel * 0.72)
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
