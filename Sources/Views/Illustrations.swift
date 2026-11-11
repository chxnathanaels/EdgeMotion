import SwiftUI

// Small illustrations used in Settings. Drawn with SwiftUI shapes so they follow
// light/dark mode and the system accent colour.

struct TrackpadSurface: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
    }
}

struct FingerDot: View {
    var color: Color = .accentColor
    var label: String? = nil
    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(color.opacity(0.85))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5))
                .frame(width: 26, height: 26)
                .shadow(color: color.opacity(0.35), radius: 6)
            if let label { Text(label).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

/// Acceleration curve: factor vs finger speed.
struct CurveGraph: View {
    var config: EMConfig
    var body: some View {
        GeometryReader { g in
            let maxV = Double(max(config.threshold * max(config.capMul, 1) * 1.15, 60))
            let maxF = max(em_curve_factor([config], maxV) * 1.15, 1.2)
            let w = g.size.width, h = g.size.height
            let left: CGFloat = 34, bottom: CGFloat = 22
            let pw = w - left - 8, ph = h - bottom - 8
            let pt: (Double, Double) -> CGPoint = { v, f in
                CGPoint(x: left + CGFloat(v / maxV) * pw, y: 8 + ph - CGFloat(f / maxF) * ph)
            }
            ZStack {
                // zones
                Path { p in
                    let z = Double(config.precZone)
                    if z > 0 { p.addRect(CGRect(x: left, y: 8, width: CGFloat(z / maxV) * pw, height: ph)) }
                }.fill(Color.green.opacity(0.10))
                Path { p in
                    let t = Double(config.threshold)
                    let x0 = left + CGFloat(t / maxV) * pw
                    p.addRect(CGRect(x: x0, y: 8, width: left + pw - x0, height: ph))
                }.fill(Color.orange.opacity(0.08))
                // grid
                Path { p in
                    for i in 0...4 {
                        let y = 8 + ph * CGFloat(i) / 4
                        p.move(to: CGPoint(x: left, y: y)); p.addLine(to: CGPoint(x: left + pw, y: y))
                    }
                }.stroke(Color.primary.opacity(0.08), lineWidth: 1)
                // 1:1 reference
                Path { p in p.move(to: pt(0, 1)); p.addLine(to: pt(maxV, 1)) }
                    .stroke(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                // curve
                Path { p in
                    let steps = 160
                    for i in 0...steps {
                        let v = maxV * Double(i) / Double(steps)
                        let q = pt(v, em_curve_factor([config], v))
                        if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
                    }
                }.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                // axes labels
                Text("finger speed →").font(.caption2).foregroundStyle(.secondary)
                    .position(x: left + pw - 40, y: h - 8)
                Text("0").font(.caption2).foregroundStyle(.secondary).position(x: left, y: h - 8)
                Text("\(Int(maxV)) mm/s").font(.caption2).foregroundStyle(.secondary).position(x: left + pw * 0.55, y: h - 8)
                Text(String(format: "%.1f×", maxF)).font(.caption2).foregroundStyle(.secondary).position(x: 16, y: 12)
                Text("1×").font(.caption2).foregroundStyle(.secondary).position(x: 16, y: pt(0, 1).y)
                if config.precZone > 0 {
                    Text("precision").font(.caption2.weight(.medium)).foregroundStyle(.green)
                        .position(x: min(left + CGFloat(Double(config.precZone) / maxV) * pw / 2 + 24, left + pw), y: 20)
                }
                Text("acceleration").font(.caption2.weight(.medium)).foregroundStyle(.orange)
                    .position(x: min(left + CGFloat(Double(config.threshold) / maxV) * pw + 44, left + pw - 30), y: 20)
            }
        }
    }
}

/// Edge motion: trackpad with the edge band highlighted.
struct EdgeIllustration: View {
    var zonePct: Double
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let band = CGFloat(zonePct / 100) * min(w, h * 1.6)
            ZStack {
                TrackpadSurface()
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.28), lineWidth: max(4, band))
                FingerDot().position(x: w - max(4, band) / 2, y: h * 0.45)
                Image(systemName: "arrow.right")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(Color.accentColor)
                    .position(x: w + 14, y: h * 0.45)
                Text("Hold your finger in the band: the pointer keeps going")
                    .font(.caption).foregroundStyle(.secondary)
                    .position(x: w / 2, y: h / 2 + 30)
            }
        }
        .padding(.trailing, 24)
    }
}

/// Dragging: one finger holds the click, the other moves.
struct DragIllustration: View {
    var body: some View {
        ZStack {
            TrackpadSurface()
            HStack(spacing: 60) {
                FingerDot(color: .gray, label: "1. press & hold")
                HStack(spacing: 6) {
                    FingerDot(label: "2. move")
                    Image(systemName: "arrow.up.right").font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}

/// Tap with N fingers.
struct TapIllustration: View {
    var fingers: Int
    var active: Bool
    var body: some View {
        ZStack {
            TrackpadSurface()
            HStack(spacing: 14) {
                ForEach(0..<fingers, id: \.self) { _ in
                    ZStack {
                        Circle().strokeBorder(Color.accentColor.opacity(active ? 0.35 : 0.15), lineWidth: 2)
                            .frame(width: 40, height: 40)
                        FingerDot(color: active ? .accentColor : .gray)
                    }
                }
            }
        }
    }
}

/// Brightness: stepped vs. smooth transition.
struct BrightnessIllustration: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                Path { p in                                   // steps
                    let steps = 4
                    for i in 0..<steps {
                        let x0 = w * CGFloat(i) / CGFloat(steps), x1 = w * CGFloat(i + 1) / CGFloat(steps)
                        let y = h - h * CGFloat(i + 1) / CGFloat(steps + 1)
                        if i == 0 { p.move(to: CGPoint(x: x0, y: h - h / CGFloat(steps + 1) + 0)) }
                        p.addLine(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y))
                    }
                }.stroke(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                Path { p in                                   // smooth
                    p.move(to: CGPoint(x: 0, y: h - h / 5))
                    p.addCurve(to: CGPoint(x: w, y: h / 5),
                               control1: CGPoint(x: w * 0.35, y: h - h / 5), control2: CGPoint(x: w * 0.55, y: h / 5))
                }.stroke(Color.accentColor, lineWidth: 2.5)
                HStack(spacing: 14) {
                    Label("stepped", systemImage: "square.dashed").foregroundStyle(.secondary)
                    Label("smooth", systemImage: "waveform.path").foregroundStyle(Color.accentColor)
                }.font(.caption2)
            }
        }
    }
}
