import Foundation

/// How viewpoints are binned.
public enum CoverageStyle: String, Codable, Sendable {
    /// Walk around an object: bins by the camera's position around the object centre.
    case orbit
    /// Stand inside a space and look around: bins by the camera's viewing direction.
    case lookAround
}

public struct CoverageRing: Sendable, Equatable, Codable {
    public var name: String
    /// Elevation band in degrees (0 = level with the centre, 90 = directly above).
    public var minElevation: Float
    public var maxElevation: Float
    public var bins: Int

    public init(name: String, minElevation: Float, maxElevation: Float, bins: Int) {
        self.name = name
        self.minElevation = minElevation
        self.maxElevation = maxElevation
        self.bins = bins
    }

    public var midElevation: Float { (minElevation + maxElevation) / 2 }

    /// Azimuth in degrees (0..<360) of the centre of `bin`.
    public func azimuth(ofBin bin: Int) -> Float { (Float(bin) + 0.5) * 360 / Float(bins) }
}

public struct CoverageCell: Hashable, Sendable {
    public var ring: Int
    public var bin: Int

    public init(ring: Int, bin: Int) {
        self.ring = ring
        self.bin = bin
    }
}

public enum GuidanceHint: Equatable, Sendable {
    case aimAtSubject
    case tooClose
    case tooFar
    case moveRight(degrees: Float)
    case moveLeft(degrees: Float)
    case moveHigher(ring: String)
    case moveLower(ring: String)
    case turnRight(degrees: Float)
    case turnLeft(degrees: Float)
    case tiltUp(ring: String)
    case tiltDown(ring: String)
    case complete

    public var message: String {
        switch self {
        case .aimAtSubject: return "被写体をカメラの中央に入れてください"
        case .tooClose: return "少し離れてください"
        case .tooFar: return "もう少し近づいてください"
        case .moveRight(let d): return "右へ回り込んでください（あと約 \(Int(d.rounded()))°）"
        case .moveLeft(let d): return "左へ回り込んでください（あと約 \(Int(d.rounded()))°）"
        case .moveHigher(let r): return "カメラを高くして「\(r)」から撮ってください"
        case .moveLower(let r): return "カメラを低くして「\(r)」から撮ってください"
        case .turnRight(let d): return "右を向いてください（あと約 \(Int(d.rounded()))°）"
        case .turnLeft(let d): return "左を向いてください（あと約 \(Int(d.rounded()))°）"
        case .tiltUp(let r): return "カメラを上に向けて「\(r)」を撮ってください"
        case .tiltDown(let r): return "カメラを下に向けて「\(r)」を撮ってください"
        case .complete: return "すべての撮影位置を撮影しました"
        }
    }
}

/// Tracks which viewpoints around a subject have been captured.
public struct CoverageMap: Sendable, Equatable {
    public var style: CoverageStyle
    public var center: Vec3
    public var rings: [CoverageRing]
    /// Camera must look within this angle of the centre for an orbit hit.
    public var maxAimAngle: Float
    /// Allowed camera distance from the centre for orbit hits.
    public var distanceRange: ClosedRange<Float>
    public var hitsPerCell: Int
    public private(set) var hits: [[Int]]

    public init(style: CoverageStyle, center: Vec3, rings: [CoverageRing], maxAimAngle: Float = 25,
                distanceRange: ClosedRange<Float> = 0...Float.greatestFiniteMagnitude, hitsPerCell: Int = 1) {
        self.style = style
        self.center = center
        self.rings = rings
        self.maxAimAngle = maxAimAngle
        self.distanceRange = distanceRange
        self.hitsPerCell = max(1, hitsPerCell)
        hits = rings.map { Array(repeating: 0, count: $0.bins) }
    }

    public var totalCells: Int { rings.reduce(0) { $0 + $1.bins } }

    public var coveredCells: Int {
        hits.reduce(0) { $0 + $1.filter { $0 >= hitsPerCell }.count }
    }

    public var fraction: Double { totalCells == 0 ? 0 : Double(coveredCells) / Double(totalCells) }

    public func isCovered(_ cell: CoverageCell) -> Bool { hits[cell.ring][cell.bin] >= hitsPerCell }

    public func ringFraction(_ ring: Int) -> Double {
        let covered = hits[ring].filter { $0 >= hitsPerCell }.count
        return Double(covered) / Double(max(rings[ring].bins, 1))
    }

    /// Direction (unit) used for binning, or nil if the pose is degenerate.
    private func bearing(of pose: CameraPose) -> Vec3? {
        let d = style == .orbit ? pose.position - center : pose.forward
        let n = normalized(d)
        return n == .zero ? nil : n
    }

    /// Elevation and azimuth (`atan2(x, z)`, 0..<360) in degrees. For an orbit, increasing azimuth means the
    /// photographer walks to their right around the subject; for a view direction it means turning left.
    public static func sphericalAngles(of dir: Vec3) -> (elevation: Float, azimuth: Float) {
        let elevation = degrees(asin(min(max(dir.y, -1), 1)))
        var azimuth = degrees(atan2(dir.x, dir.z))
        if azimuth < 0 { azimuth += 360 }
        return (elevation, azimuth)
    }

    public func angles(of pose: CameraPose) -> (elevation: Float, azimuth: Float)? {
        bearing(of: pose).map(Self.sphericalAngles)
    }

    public func ringIndex(elevation: Float) -> Int? {
        rings.firstIndex { elevation >= $0.minElevation && elevation < $0.maxElevation }
    }

    public func cell(for pose: CameraPose) -> CoverageCell? {
        guard let a = angles(of: pose), let r = ringIndex(elevation: a.elevation) else { return nil }
        let bins = rings[r].bins
        let bin = min(Int(a.azimuth / 360 * Float(bins)), bins - 1)
        return CoverageCell(ring: r, bin: bin)
    }

    public func aimAngle(of pose: CameraPose) -> Float {
        angleBetween(pose.forward, center - pose.position)
    }

    /// Whether a photo taken from `pose` would count toward coverage.
    public func isValidViewpoint(_ pose: CameraPose) -> Bool {
        guard style == .orbit else { return true }
        let dist = length(pose.position - center)
        return aimAngle(of: pose) <= maxAimAngle && distanceRange.contains(dist)
    }

    /// Records a captured view. Returns the cell if it became newly covered.
    @discardableResult
    public mutating func record(_ pose: CameraPose) -> CoverageCell? {
        guard isValidViewpoint(pose), let c = cell(for: pose) else { return nil }
        let before = hits[c.ring][c.bin]
        hits[c.ring][c.bin] = before + 1
        return before + 1 == hitsPerCell ? c : nil
    }

    /// Unit direction from the centre (orbit) or from the camera (look-around) for a cell centre.
    public func direction(of cell: CoverageCell) -> Vec3 {
        let ring = rings[cell.ring]
        let el = radians(ring.midElevation)
        let az = radians(ring.azimuth(ofBin: cell.bin))
        return Vec3(cos(el) * sin(az), sin(el), cos(el) * cos(az))
    }

    /// Next instruction for the photographer.
    public func guidance(for pose: CameraPose) -> GuidanceHint {
        guard coveredCells < totalCells else { return .complete }
        if style == .orbit {
            if aimAngle(of: pose) > maxAimAngle { return .aimAtSubject }
            let dist = length(pose.position - center)
            if dist < distanceRange.lowerBound { return .tooClose }
            if dist > distanceRange.upperBound { return .tooFar }
        }
        guard let a = angles(of: pose) else { return .aimAtSubject }
        let current = ringIndex(elevation: a.elevation)
        let targetRing: Int
        if let current, hits[current].contains(where: { $0 < hitsPerCell }) {
            targetRing = current
        } else {
            let pending = rings.indices.filter { r in hits[r].contains { $0 < hitsPerCell } }
            targetRing = pending.min { abs(rings[$0].midElevation - a.elevation) < abs(rings[$1].midElevation - a.elevation) }!
            if targetRing != current {
                let higher = rings[targetRing].midElevation > a.elevation
                let name = rings[targetRing].name
                switch style {
                case .orbit: return higher ? .moveHigher(ring: name) : .moveLower(ring: name)
                case .lookAround: return higher ? .tiltUp(ring: name) : .tiltDown(ring: name)
                }
            }
        }
        let ring = rings[targetRing]
        var best: Float?
        for bin in 0..<ring.bins where hits[targetRing][bin] < hitsPerCell {
            let d = wrappedDelta(from: a.azimuth, to: ring.azimuth(ofBin: bin))
            if best == nil || abs(d) < abs(best!) { best = d }
        }
        let delta = best ?? 0
        switch style {
        case .orbit: return delta >= 0 ? .moveRight(degrees: delta) : .moveLeft(degrees: -delta)
        case .lookAround: return delta >= 0 ? .turnLeft(degrees: delta) : .turnRight(degrees: -delta)
        }
    }
}
