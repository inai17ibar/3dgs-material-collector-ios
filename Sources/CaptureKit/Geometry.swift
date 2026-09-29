import Foundation

public typealias Vec3 = SIMD3<Float>

func dot(_ a: Vec3, _ b: Vec3) -> Float { (a * b).sum() }

func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
    Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

func length(_ a: Vec3) -> Float { dot(a, a).squareRoot() }

func normalized(_ a: Vec3) -> Vec3 {
    let l = length(a)
    return l > 1e-9 ? a / l : .zero
}

func degrees(_ r: Float) -> Float { r * 180 / .pi }
func radians(_ d: Float) -> Float { d * .pi / 180 }

/// Angle between two directions in degrees.
func angleBetween(_ a: Vec3, _ b: Vec3) -> Float {
    let c = dot(normalized(a), normalized(b))
    return degrees(acos(min(max(c, -1), 1)))
}

/// Signed difference `b - a` of two angles in degrees, wrapped to -180..<180.
func wrappedDelta(from a: Float, to b: Float) -> Float {
    var d = (b - a).truncatingRemainder(dividingBy: 360)
    if d >= 180 { d -= 360 }
    if d < -180 { d += 360 }
    return d
}

/// Camera pose in ARKit convention: gravity-aligned world with +y up; camera looks along its local -z.
public struct CameraPose: Sendable, Equatable, Codable {
    public var position: Vec3
    /// Columns of the camera→world rotation: camera +x, +y, +z expressed in world space.
    public var right: Vec3
    public var up: Vec3
    public var back: Vec3

    public init(position: Vec3, right: Vec3, up: Vec3, back: Vec3) {
        self.position = position
        self.right = right
        self.up = up
        self.back = back
    }

    /// Builds a pose from the four columns of a 4×4 camera→world transform (e.g. `ARCamera.transform`).
    public init(columns c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) {
        self.init(position: Vec3(c3.x, c3.y, c3.z), right: Vec3(c0.x, c0.y, c0.z),
                  up: Vec3(c1.x, c1.y, c1.z), back: Vec3(c2.x, c2.y, c2.z))
    }

    public var forward: Vec3 { -back }

    /// Camera looking from `eye` toward `target` with world +y as up hint.
    public static func looking(from eye: Vec3, at target: Vec3, worldUp: Vec3 = Vec3(0, 1, 0)) -> CameraPose {
        let f = normalized(target - eye)
        var r = cross(f, worldUp)
        if length(r) < 1e-5 { r = Vec3(1, 0, 0) }
        r = normalized(r)
        let u = cross(r, f)
        return CameraPose(position: eye, right: r, up: u, back: -f)
    }
}
