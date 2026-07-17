import SwiftUI

/// Renders the spectrum with SwiftUI Canvas. Redraws when the levels change.
struct VisualizerView: View {
    let levels: [Float]
    let peaks: [Float]
    @ObservedObject var settings: VisualizerSettings

    var body: some View {
        Canvas { context, size in
            guard !levels.isEmpty else { return }
            switch settings.theme {
            case .bars:     drawBars(context: &context, size: size, mirrored: false)
            case .mirror:   drawBars(context: &context, size: size, mirrored: true)
            case .circular: drawCircular(context: &context, size: size)
            case .line:     drawLine(context: &context, size: size)
            }
        }
        .background(Color.black)
        .drawingGroup()
    }

    // MARK: - Bars / Mirror

    private func drawBars(context: inout GraphicsContext, size: CGSize, mirrored: Bool) {
        let n = levels.count
        guard n > 0 else { return }
        let gap = size.width / CGFloat(n) * 0.18
        let barWidth = (size.width - gap * CGFloat(n)) / CGFloat(n)
        let baseY = mirrored ? size.height / 2 : size.height
        let maxH = mirrored ? size.height / 2 : size.height

        for i in 0..<n {
            let h = CGFloat(levels[i]) * maxH
            let x = CGFloat(i) * (barWidth + gap) + gap / 2
            let pos = Double(i) / Double(max(1, n - 1))
            let color = settings.colorScheme.color(height: Double(levels[i]), position: pos)

            // Bar going up.
            let rectUp = CGRect(x: x, y: baseY - h, width: barWidth, height: h)
            context.fill(Path(roundedRect: rectUp, cornerRadius: min(2, barWidth / 3)),
                         with: .color(color))

            if mirrored {
                let rectDown = CGRect(x: x, y: baseY, width: barWidth, height: h)
                context.fill(Path(roundedRect: rectDown, cornerRadius: min(2, barWidth / 3)),
                             with: .color(color.opacity(0.55)))
            }

            // Peak cap.
            if settings.peakHold, i < peaks.count {
                let ph = CGFloat(peaks[i]) * maxH
                let capY = baseY - ph
                let capRect = CGRect(x: x, y: capY - 2, width: barWidth, height: 2)
                context.fill(Path(capRect), with: .color(.white.opacity(0.85)))
                if mirrored {
                    let capRectD = CGRect(x: x, y: baseY + ph, width: barWidth, height: 2)
                    context.fill(Path(capRectD), with: .color(.white.opacity(0.5)))
                }
            }
        }
    }

    // MARK: - Circular

    private func drawCircular(context: inout GraphicsContext, size: CGSize) {
        let n = levels.count
        guard n > 0 else { return }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let innerR = min(size.width, size.height) * 0.18
        let maxLen = min(size.width, size.height) * 0.30

        for i in 0..<n {
            let angle = (Double(i) / Double(n)) * 2 * .pi - .pi / 2
            let len = CGFloat(levels[i]) * maxLen
            let pos = Double(i) / Double(max(1, n - 1))
            let color = settings.colorScheme.color(height: Double(levels[i]), position: pos)

            let p0 = CGPoint(x: center.x + cos(angle) * innerR,
                             y: center.y + sin(angle) * innerR)
            let p1 = CGPoint(x: center.x + cos(angle) * (innerR + len),
                             y: center.y + sin(angle) * (innerR + len))
            var path = Path()
            path.move(to: p0)
            path.addLine(to: p1)
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: max(1.5, size.width / CGFloat(n) * 0.6),
                                              lineCap: .round))
        }
    }

    // MARK: - Line

    private func drawLine(context: inout GraphicsContext, size: CGSize) {
        let n = levels.count
        guard n > 1 else { return }
        var path = Path()
        for i in 0..<n {
            let x = size.width * CGFloat(i) / CGFloat(n - 1)
            let y = size.height - CGFloat(levels[i]) * size.height
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        // Gradient fill under the curve.
        var fill = path
        fill.addLine(to: CGPoint(x: size.width, y: size.height))
        fill.addLine(to: CGPoint(x: 0, y: size.height))
        fill.closeSubpath()

        let c0 = settings.colorScheme.color(height: 0.9, position: 0.5)
        context.fill(fill, with: .linearGradient(
            Gradient(colors: [c0.opacity(0.6), c0.opacity(0.05)]),
            startPoint: CGPoint(x: 0, y: 0),
            endPoint: CGPoint(x: 0, y: size.height)))
        context.stroke(path, with: .color(c0),
                       style: StrokeStyle(lineWidth: 2, lineJoin: .round))
    }
}
