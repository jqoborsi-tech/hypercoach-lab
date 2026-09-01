import SwiftUI

enum Palette {
    static let background = Color(red: 0.043, green: 0.043, blue: 0.051)
    static let card = Color(red: 0.082, green: 0.082, blue: 0.094)
    static let card2 = Color(red: 0.125, green: 0.125, blue: 0.141)
    static let line = Color(red: 0.149, green: 0.149, blue: 0.169)
    static let ink = Color(red: 0.957, green: 0.957, blue: 0.961)
    static let muted = Color(red: 0.631, green: 0.631, blue: 0.667)
    static let accent = Color(red: 0.416, green: 0.639, blue: 0.851)
    static let good = Color(red: 0.310, green: 0.706, blue: 0.467)
    static let warn = Color(red: 0.851, green: 0.580, blue: 0.169)
    static let bad = Color(red: 0.851, green: 0.173, blue: 0.173)
}

struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .kerning(1.1)
                    .foregroundStyle(Palette.muted)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.line, lineWidth: 1))
    }
}

struct StatRow: View {
    var label: String
    var value: String
    var tint: Color = Palette.ink

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Palette.muted)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(tint).monospacedDigit()
        }
        .font(.subheadline)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Palette.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(tint.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(Color.black.opacity(0.9))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Palette.card2.opacity(configuration.isPressed ? 0.6 : 1),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(Palette.ink)
    }
}

/// Ring of yaw bins that fills in as the operator sweeps around the face.
struct CoverageDial: View {
    var yawBins: Set<Int>
    var pitchBins: Set<Int>
    var currentYaw: Float

    var body: some View {
        ZStack {
            ForEach(0..<CoverageBins.yawCount, id: \.self) { bin in
                let filled = yawBins.contains(bin)
                let angle = Double(bin - CoverageBins.yawCount / 2) * 12.0
                Capsule()
                    .fill(filled ? Palette.good : Palette.line)
                    .frame(width: 5, height: filled ? 20 : 13)
                    .offset(y: -44)
                    .rotationEffect(.degrees(angle))
            }
            let currentAngle = Double(max(-70, min(70, currentYaw))) * 1.2
            Triangle()
                .fill(Palette.accent)
                .frame(width: 12, height: 9)
                .offset(y: -64)
                .rotationEffect(.degrees(currentAngle))
            VStack(spacing: 2) {
                Text("\(yawBins.count * 10)°")
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(Palette.ink)
                Text("sweep")
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(width: 132, height: 132)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct QualityBadge: View {
    var quality: CaptureQuality

    private var tint: Color {
        switch quality.coverageScore {
        case ..<0.45: return Palette.bad
        case ..<0.75: return Palette.warn
        default:      return Palette.good
        }
    }

    private var label: String {
        switch quality.coverageScore {
        case ..<0.45: return "Partial"
        case ..<0.75: return "Usable"
        default:      return "Full sweep"
        }
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}
