import SwiftUI

struct NavigationArrow: Equatable, Identifiable {
    let id: UUID
    let sourceWindowRect: CGRect
    let targetWindowRect: CGRect
}

struct NavigationArrowOverlay: View {
    let arrow: NavigationArrow?

    var body: some View {
        GeometryReader { geo in
            if let arrow {
                let origin = geo.frame(in: .global).origin
                let start = midPoint(of: arrow.sourceWindowRect, relativeTo: origin)
                let end = midPoint(of: arrow.targetWindowRect, relativeTo: origin)
                ArrowShape(start: start, end: end)
                    .stroke(arrowGradient,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
                    .transition(.opacity)
                    .id(arrow.id)
            }
        }
        .animation(.easeOut(duration: 0.35), value: arrow?.id)
    }

    private var arrowGradient: LinearGradient {
        LinearGradient(colors: [Color.accentColor.opacity(0.0),
                                Color.accentColor.opacity(0.95)],
                       startPoint: .leading,
                       endPoint: .trailing)
    }

    private func midPoint(of rect: CGRect, relativeTo origin: CGPoint) -> CGPoint {
        CGPoint(x: rect.midX - origin.x, y: rect.midY - origin.y)
    }
}

private struct ArrowShape: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = max(1, hypot(dx, dy))

        // Bow the curve toward the side opposite to the travel direction so it
        // arcs through empty space rather than over either pane's content.
        let bend: CGFloat = min(220, distance * 0.35)
        let midX = (start.x + end.x) * 0.5
        let midY = (start.y + end.y) * 0.5
        // Perpendicular vector (left-hand normal) — arc upward by default.
        let nx = -dy / distance
        let ny = dx / distance
        let control = CGPoint(x: midX + nx * bend, y: midY + ny * bend - bend * 0.2)

        path.move(to: start)
        path.addQuadCurve(to: end, control: control)

        // Arrowhead: tangent at endpoint = derivative of quadratic at t=1
        let tangentX = 2 * (end.x - control.x)
        let tangentY = 2 * (end.y - control.y)
        let tangentLen = max(1, hypot(tangentX, tangentY))
        let tx = tangentX / tangentLen
        let ty = tangentY / tangentLen
        let headLength: CGFloat = 14
        let headWidth: CGFloat = 9
        let baseX = end.x - tx * headLength
        let baseY = end.y - ty * headLength
        let leftX = baseX + (-ty) * headWidth
        let leftY = baseY + tx * headWidth
        let rightX = baseX - (-ty) * headWidth
        let rightY = baseY - tx * headWidth
        path.move(to: CGPoint(x: leftX, y: leftY))
        path.addLine(to: end)
        path.addLine(to: CGPoint(x: rightX, y: rightY))

        return path
    }
}
