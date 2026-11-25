import SwiftUI

struct SightportMark: View {
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            context.translateBy(x: (size.width - side) / 2, y: (size.height - side) / 2)
            context.scaleBy(x: side / 128, y: side / 128)
            let tile = RoundedRectangle(cornerRadius: 28, style: .continuous)
                .path(in: CGRect(x: 0.5, y: 0.5, width: 127, height: 127))
            let mint = Gradient(colors: [
                Color(red: 0.80, green: 0.97, blue: 0.86),
                Color(red: 0.67, green: 0.91, blue: 0.78),
                Color(red: 0.54, green: 0.84, blue: 0.70)
            ])
            context.fill(tile, with: .linearGradient(mint,
                startPoint: CGPoint(x: 20, y: 0), endPoint: CGPoint(x: 96, y: 128)))
            context.stroke(tile, with: .color(.white.opacity(0.28)), lineWidth: 1)

            // Each folded band forms two adjoining sides of the hexagonal opening.
            let outer = Self.polygon([(28, 43.2), (64, 22.4), (88.2, 36.4),
                                      (73.2, 45.1), (64, 39.8), (43, 51.9),
                                      (43, 61.1), (28, 52.4)])
            let fold = Self.polygon([(28, 43.2), (43, 51.9), (43, 61.1), (28, 52.4)])
            let faces: [Color] = [
                Color(red: 0.09, green: 0.31, blue: 0.27),
                Color(red: 0.06, green: 0.26, blue: 0.24),
                Color(red: 0.14, green: 0.37, blue: 0.31)
            ]
            let core = Self.polygon([(64, 52), (74.4, 58), (74.4, 70),
                                     (64, 76), (53.6, 70), (53.6, 58)])
            context.fill(core, with: .color(faces[0]))
            let coreTop = Self.polygon([(64, 52), (74.4, 58), (64, 64), (53.6, 58)])
            context.fill(coreTop, with: .color(faces[2]))
            context.translateBy(x: 64, y: 64)
            for face in faces {
                var band = context
                band.translateBy(x: -64, y: -64)
                band.fill(outer, with: .color(face))
                band.fill(fold, with: .color(.white.opacity(0.11)))
                context.rotate(by: .degrees(120))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private static func polygon(_ points: [(CGFloat, CGFloat)]) -> Path {
        Path { path in
            for (index, point) in points.enumerated() {
                let vertex = CGPoint(x: point.0, y: point.1)
                if index == 0 { path.move(to: vertex) } else { path.addLine(to: vertex) }
            }
            path.closeSubpath()
        }
    }
}
