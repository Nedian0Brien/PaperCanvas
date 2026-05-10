import CoreGraphics
import Foundation

struct InkRenderSample: Equatable {
    var location: CGPoint
    var force: CGFloat
    var altitude: CGFloat
    var azimuth: CGFloat
}

struct InkStrokeOutline: Equatable {
    var leftEdge: [CGPoint]
    var rightEdge: [CGPoint]
    var bounds: CGRect

    func makeClosedPath() -> CGPath {
        let path = CGMutablePath()
        guard let firstLeft = leftEdge.first,
              let firstRight = rightEdge.first else {
            return path
        }

        if leftEdge.count == 1, rightEdge.count == 1 {
            let center = midpoint(firstLeft, firstRight)
            let radius = max(distance(firstLeft, firstRight) * 0.5, 0.5)
            path.addEllipse(in: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            return path
        }

        path.move(to: firstLeft)
        addSmoothPolyline(leftEdge, to: path)

        addCap(
            to: path,
            from: leftEdge.last,
            to: rightEdge.last,
            referenceFrom: leftEdge.dropLast().last,
            referenceTo: rightEdge.dropLast().last
        )

        addSmoothPolyline(Array(rightEdge.reversed()), to: path)

        addCap(
            to: path,
            from: firstRight,
            to: firstLeft,
            referenceFrom: rightEdge.dropFirst().first,
            referenceTo: leftEdge.dropFirst().first
        )
        path.closeSubpath()
        return path
    }
}

enum InkStrokeGeometry {
    static func outline(for stroke: InkStroke, isComplete: Bool = true) -> InkStrokeOutline? {
        outline(
            for: stroke.points.map {
                InkRenderSample(
                    location: $0.location,
                    force: $0.force,
                    altitude: $0.altitude,
                    azimuth: $0.azimuth
                )
            },
            tool: stroke.tool,
            baseWidth: stroke.baseWidth,
            isComplete: isComplete
        )
    }

    static func outline(for samples: [InkRenderSample],
                        tool: InkTool,
                        baseWidth: CGFloat,
                        isComplete: Bool = true) -> InkStrokeOutline? {
        let samples = streamlinedSamples(
            filteredSamples(samples, baseWidth: baseWidth),
            tool: tool
        )
        guard !samples.isEmpty else { return nil }

        if samples.count == 1 {
            let radius = width(for: samples[0], at: 0, in: samples, tool: tool, baseWidth: baseWidth) * 0.5
            let center = samples[0].location
            let outline = InkStrokeOutline(
                leftEdge: [CGPoint(x: center.x, y: center.y - radius)],
                rightEdge: [CGPoint(x: center.x, y: center.y + radius)],
                bounds: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
            return outline
        }

        var leftEdge: [CGPoint] = []
        var rightEdge: [CGPoint] = []
        leftEdge.reserveCapacity(samples.count)
        rightEdge.reserveCapacity(samples.count)

        let distances = cumulativeDistances(for: samples)
        let totalLength = distances.last ?? 0
        for index in samples.indices {
            let sample = samples[index]
            let tangent = tangentVector(at: index, in: samples)
            let normal = CGPoint(x: -tangent.y, y: tangent.x)
            let radius = width(
                for: sample,
                at: index,
                in: samples,
                distanceFromStart: distances[index],
                totalLength: totalLength,
                tool: tool,
                baseWidth: baseWidth,
                isComplete: isComplete
            ) * 0.5

            leftEdge.append(CGPoint(
                x: sample.location.x + normal.x * radius,
                y: sample.location.y + normal.y * radius
            ))
            rightEdge.append(CGPoint(
                x: sample.location.x - normal.x * radius,
                y: sample.location.y - normal.y * radius
            ))
        }

        var outline = InkStrokeOutline(
            leftEdge: leftEdge,
            rightEdge: rightEdge,
            bounds: .zero
        )
        outline.bounds = outline.makeClosedPath().boundingBoxOfPath
        return outline
    }

    private static func filteredSamples(_ samples: [InkRenderSample],
                                        baseWidth: CGFloat) -> [InkRenderSample] {
        let minimumDistance = max(baseWidth * 0.025, 0.08)
        var result: [InkRenderSample] = []
        result.reserveCapacity(samples.count)

        for sample in samples where sample.location.x.isFinite && sample.location.y.isFinite {
            guard let last = result.last else {
                result.append(sample)
                continue
            }
            if distance(last.location, sample.location) < minimumDistance {
                result[result.count - 1] = sample
            } else {
                result.append(sample)
            }
        }
        return result
    }

    private static func streamlinedSamples(_ samples: [InkRenderSample],
                                           tool: InkTool) -> [InkRenderSample] {
        guard samples.count > 2 else { return samples }
        let strength: CGFloat
        switch tool {
        case .pen:
            strength = 0.10
        case .gelPen:
            strength = 0.22
        case .fountainPen:
            strength = 0.16
        case .brushPen:
            strength = 0.20
        case .pencil:
            strength = 0.24
        case .marker, .highlighter:
            strength = 0.10
        case .eraser:
            strength = 0
        }
        guard strength > 0 else { return samples }

        var result = samples
        for index in samples.index(after: samples.startIndex)..<samples.index(before: samples.endIndex) {
            let previous = samples[index - 1].location
            let current = samples[index].location
            let next = samples[index + 1].location
            let target = midpoint(previous, next)
            result[index].location = CGPoint(
                x: current.x + (target.x - current.x) * strength,
                y: current.y + (target.y - current.y) * strength
            )
        }
        return result
    }

    private static func cumulativeDistances(for samples: [InkRenderSample]) -> [CGFloat] {
        guard !samples.isEmpty else { return [] }
        var distances = Array(repeating: CGFloat.zero, count: samples.count)
        for index in samples.indices.dropFirst() {
            distances[index] = distances[index - 1] + distance(
                samples[index - 1].location,
                samples[index].location
            )
        }
        return distances
    }

    private static func tangentVector(at index: Int, in samples: [InkRenderSample]) -> CGPoint {
        let previous = samples[max(samples.startIndex, index - 2)].location
        let next = samples[min(samples.index(before: samples.endIndex), index + 2)].location
        let dx = next.x - previous.x
        let dy = next.y - previous.y
        let length = hypot(dx, dy)
        guard length > 0 else { return CGPoint(x: 1, y: 0) }
        return CGPoint(x: dx / length, y: dy / length)
    }

    private static func width(for sample: InkRenderSample,
                              at index: Int,
                              in samples: [InkRenderSample],
                              tool: InkTool,
                              baseWidth: CGFloat) -> CGFloat {
        width(
            for: sample,
            at: index,
            in: samples,
            distanceFromStart: 0,
            totalLength: 0,
            tool: tool,
            baseWidth: baseWidth,
            isComplete: true
        )
    }

    private static func width(for sample: InkRenderSample,
                              at index: Int,
                              in samples: [InkRenderSample],
                              distanceFromStart: CGFloat,
                              totalLength: CGFloat,
                              tool: InkTool,
                              baseWidth: CGFloat,
                              isComplete: Bool) -> CGFloat {
        let pressure = smoothedPressure(at: index, in: samples)
        let curvedPressure = pow(pressure, 0.72)
        let uprightAltitude = CGFloat.pi / 2
        let tilt = 1 - clamp(sample.altitude / uprightAltitude, lower: 0, upper: 1)

        let factor: CGFloat
        switch tool {
        case .pen:
            factor = 0.88 + curvedPressure * 0.22
        case .gelPen:
            factor = 0.82 + curvedPressure * 0.32
        case .fountainPen:
            factor = 0.62 + curvedPressure * 0.62
        case .brushPen:
            factor = 0.40 + curvedPressure * 1.05
        case .pencil:
            factor = 0.35 + curvedPressure * 0.75 + tilt * 0.30
        case .marker, .highlighter:
            factor = 0.82 + curvedPressure * 0.25
        case .eraser:
            factor = 1
        }

        let naturalWidth = max(baseWidth * factor, 0.75)
        let taperedWidth = naturalWidth * taperFactor(
            distanceFromStart: distanceFromStart,
            totalLength: totalLength,
            tool: tool,
            baseWidth: baseWidth,
            isComplete: isComplete
        )
        return max(taperedWidth, minimumRenderedWidth(for: tool, baseWidth: baseWidth, isComplete: isComplete))
    }

    private static func smoothedPressure(at index: Int, in samples: [InkRenderSample]) -> CGFloat {
        var total: CGFloat = 0
        var weight: CGFloat = 0
        for offset in -2...2 {
            let candidate = index + offset
            guard samples.indices.contains(candidate) else { continue }
            let sampleWeight: CGFloat
            switch abs(offset) {
            case 0:
                sampleWeight = 0.4
            case 1:
                sampleWeight = 0.2
            default:
                sampleWeight = 0.1
            }
            total += normalizedPressure(samples[candidate].force) * sampleWeight
            weight += sampleWeight
        }
        guard weight > 0 else { return normalizedPressure(samples[index].force) }
        return total / weight
    }

    private static func normalizedPressure(_ force: CGFloat) -> CGFloat {
        clamp(force.isFinite ? force : 1, lower: 0.05, upper: 1)
    }

    private static func taperFactor(distanceFromStart: CGFloat,
                                    totalLength: CGFloat,
                                    tool: InkTool,
                                    baseWidth: CGFloat,
                                    isComplete: Bool) -> CGFloat {
        guard totalLength > 0 else { return 1 }

        switch tool {
        case .pen:
            let distanceToEnd = max(totalLength - distanceFromStart, 0)
            let startLength = min(totalLength * 0.25, max(baseWidth * 0.70, 3))
            let endLength = min(totalLength * 0.30, max(baseWidth * 0.90, 4))
            let startFactor = 0.82 + 0.18 * easeOutCubic(startLength > 0 ? distanceFromStart / startLength : 1)
            let endFloor: CGFloat = isComplete ? 0.72 : 0.88
            let endFactor = endFloor + (1 - endFloor) * easeOutCubic(endLength > 0 ? distanceToEnd / endLength : 1)
            return min(startFactor, endFactor)

        case .gelPen:
            let distanceToEnd = max(totalLength - distanceFromStart, 0)
            let startLength = min(totalLength * 0.28, max(baseWidth * 0.85, 4))
            let endLength = min(totalLength * 0.34, max(baseWidth * 1.00, 5))
            let startFactor = 0.76 + 0.24 * easeOutCubic(startLength > 0 ? distanceFromStart / startLength : 1)
            let endFloor: CGFloat = isComplete ? 0.68 : 0.86
            let endFactor = endFloor + (1 - endFloor) * easeOutCubic(endLength > 0 ? distanceToEnd / endLength : 1)
            return min(startFactor, endFactor)

        case .fountainPen:
            let distanceToEnd = max(totalLength - distanceFromStart, 0)
            let startLength = min(totalLength * 0.38, max(baseWidth * 1.60, 6))
            let endLength = min(totalLength * 0.44, max(baseWidth * 1.90, 7))
            let startFactor = 0.54 + 0.46 * easeOutCubic(startLength > 0 ? distanceFromStart / startLength : 1)
            let endFloor: CGFloat = isComplete ? 0.40 : 0.72
            let endFactor = endFloor + (1 - endFloor) * easeOutCubic(endLength > 0 ? distanceToEnd / endLength : 1)
            return min(startFactor, endFactor)

        case .brushPen, .pencil:
            let distanceToEnd = max(totalLength - distanceFromStart, 0)
            let startLength = min(totalLength * 0.45, max(baseWidth * 2.2, 7))
            let endLength = min(totalLength * 0.55, max(baseWidth * 2.8, 9))
            let startFloor: CGFloat = tool == .pencil ? 0.20 : 0.24
            let endFloor: CGFloat = isComplete ? (tool == .pencil ? 0.12 : 0.16) : 0.55

            let startProgress = startLength > 0 ? clamp(distanceFromStart / startLength, lower: 0, upper: 1) : 1
            let endProgress = endLength > 0 ? clamp(distanceToEnd / endLength, lower: 0, upper: 1) : 1
            let startFactor = startFloor + (1 - startFloor) * easeOutCubic(startProgress)
            let endFactor = endFloor + (1 - endFloor) * easeOutCubic(endProgress)
            return min(startFactor, endFactor)

        case .marker, .highlighter, .eraser:
            return 1
        }
    }

    private static func minimumRenderedWidth(for tool: InkTool,
                                             baseWidth: CGFloat,
                                             isComplete: Bool) -> CGFloat {
        switch tool {
        case .pen:
            return max(baseWidth * (isComplete ? 0.58 : 0.74), 0.75)
        case .gelPen:
            return max(baseWidth * (isComplete ? 0.52 : 0.70), 0.75)
        case .fountainPen:
            return max(baseWidth * (isComplete ? 0.30 : 0.56), 0.65)
        case .brushPen:
            return max(baseWidth * (isComplete ? 0.10 : 0.35), 0.55)
        case .pencil:
            return max(baseWidth * (isComplete ? 0.08 : 0.30), 0.45)
        case .marker, .highlighter:
            return max(baseWidth * 0.70, 1)
        case .eraser:
            return max(baseWidth, 1)
        }
    }

    private static func easeOutCubic(_ value: CGFloat) -> CGFloat {
        let t = clamp(value, lower: 0, upper: 1)
        return 1 - pow(1 - t, 3)
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}

private func addSmoothPolyline(_ points: [CGPoint], to path: CGMutablePath) {
    guard points.count > 1 else { return }
    if points.count == 2 {
        path.addLine(to: points[1])
        return
    }

    for index in 1..<(points.count - 1) {
        let current = points[index]
        let next = points[index + 1]
        path.addQuadCurve(to: midpoint(current, next), control: current)
    }

    if let last = points.last, points.count >= 2 {
        path.addQuadCurve(to: last, control: points[points.count - 2])
    }
}

private func addCap(to path: CGMutablePath,
                    from start: CGPoint?,
                    to end: CGPoint?,
                    referenceFrom: CGPoint?,
                    referenceTo: CGPoint?) {
    guard let start, let end else { return }
    if shouldUsePointedCap(start: start, end: end, referenceFrom: referenceFrom, referenceTo: referenceTo) {
        path.addQuadCurve(to: end, control: midpoint(start, end))
        return
    }

    let center = midpoint(start, end)
    let radius = distance(start, end) * 0.5
    guard radius > 0 else {
        path.addLine(to: end)
        return
    }

    let startAngle = atan2(start.y - center.y, start.x - center.x)
    let endAngle = atan2(end.y - center.y, end.x - center.x)
    let steps = 6
    for step in 1...steps {
        let progress = CGFloat(step) / CGFloat(steps)
        let angle = clockwiseAngle(from: startAngle, to: endAngle, progress: progress)
        path.addLine(to: CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        ))
    }
}

private func shouldUsePointedCap(start: CGPoint,
                                 end: CGPoint,
                                 referenceFrom: CGPoint?,
                                 referenceTo: CGPoint?) -> Bool {
    guard let referenceFrom, let referenceTo else { return false }
    let capWidth = distance(start, end)
    let referenceWidth = distance(referenceFrom, referenceTo)
    return referenceWidth > 0 && capWidth < referenceWidth * 0.72
}

private func clockwiseAngle(from start: CGFloat, to end: CGFloat, progress: CGFloat) -> CGFloat {
    var delta = end - start
    if delta > 0 {
        delta -= CGFloat.pi * 2
    }
    return start + delta * progress
}

private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
    CGPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
}
