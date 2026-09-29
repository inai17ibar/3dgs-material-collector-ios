import Foundation

public struct CameraIntrinsics: Codable, Equatable, Hashable, Sendable {
    public var fx: Float
    public var fy: Float
    public var cx: Float
    public var cy: Float
    public var width: Int
    public var height: Int

    public init(fx: Float, fy: Float, cx: Float, cy: Float, width: Int, height: Int) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
    }

    /// Rescales to another image size (e.g. intrinsics of the preview stream applied to a high-res photo).
    public func scaled(toWidth w: Int, height h: Int) -> CameraIntrinsics {
        let sx = Float(w) / Float(width), sy = Float(h) / Float(height)
        return CameraIntrinsics(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy, width: w, height: h)
    }
}

public struct CapturedFrame: Codable, Equatable, Sendable {
    /// Path relative to the capture folder, e.g. `images/frame_00001.jpg`.
    public var file: String
    public var time: Double
    public var pose: CameraPose
    public var intrinsics: CameraIntrinsics

    public init(file: String, time: Double, pose: CameraPose, intrinsics: CameraIntrinsics) {
        self.file = file
        self.time = time
        self.pose = pose
        self.intrinsics = intrinsics
    }
}

/// Everything recorded for one capture, written as `manifest.json` next to the images/video.
public struct CaptureManifest: Codable, Equatable, Sendable {
    public var version = 1
    public var createdAt: Date
    public var device: String
    public var subject: SubjectSize
    public var mode: CaptureMode
    public var center: Vec3
    public var coverage: Double
    public var video: String?
    public var frames: [CapturedFrame]

    public init(createdAt: Date, device: String, subject: SubjectSize, mode: CaptureMode, center: Vec3,
                coverage: Double, video: String? = nil, frames: [CapturedFrame]) {
        self.createdAt = createdAt
        self.device = device
        self.subject = subject
        self.mode = mode
        self.center = center
        self.coverage = coverage
        self.video = video
        self.frames = frames
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> CaptureManifest {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(CaptureManifest.self, from: data)
    }
}

public struct Quaternion: Equatable, Sendable {
    public var w, x, y, z: Float
}

public enum PoseExport {
    /// Quaternion of a rotation matrix given by rows `r0, r1, r2`.
    public static func quaternion(rows r0: Vec3, _ r1: Vec3, _ r2: Vec3) -> Quaternion {
        let trace = r0.x + r1.y + r2.z
        var q: Quaternion
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            q = Quaternion(w: s / 4, x: (r2.y - r1.z) / s, y: (r0.z - r2.x) / s, z: (r1.x - r0.y) / s)
        } else if r0.x > r1.y && r0.x > r2.z {
            let s = (1 + r0.x - r1.y - r2.z).squareRoot() * 2
            q = Quaternion(w: (r2.y - r1.z) / s, x: s / 4, y: (r0.y + r1.x) / s, z: (r0.z + r2.x) / s)
        } else if r1.y > r2.z {
            let s = (1 + r1.y - r0.x - r2.z).squareRoot() * 2
            q = Quaternion(w: (r0.z - r2.x) / s, x: (r0.y + r1.x) / s, y: s / 4, z: (r1.z + r2.y) / s)
        } else {
            let s = (1 + r2.z - r0.x - r1.y).squareRoot() * 2
            q = Quaternion(w: (r1.x - r0.y) / s, x: (r0.z + r2.x) / s, y: (r1.z + r2.y) / s, z: s / 4)
        }
        if q.w < 0 { q = Quaternion(w: -q.w, x: -q.x, y: -q.y, z: -q.z) }
        return q
    }

    /// COLMAP world→camera pose (camera x right, y down, z forward) for an ARKit camera→world pose.
    public static func colmapPose(_ pose: CameraPose) -> (rotation: Quaternion, translation: Vec3) {
        // Rows of R_w2c are the COLMAP camera axes in world space.
        let r0 = pose.right, r1 = -pose.up, r2 = pose.forward
        let t = -Vec3(dot(r0, pose.position), dot(r1, pose.position), dot(r2, pose.position))
        return (quaternion(rows: r0, r1, r2), t)
    }

    /// COLMAP sparse text model (`cameras.txt`, `images.txt`, `points3D.txt`) with known poses and no points,
    /// suitable for `colmap point_triangulator`. Image names are the file names inside `images/`.
    public static func colmapText(_ manifest: CaptureManifest) -> (cameras: String, images: String, points: String) {
        var cameraIDs: [CameraIntrinsics: Int] = [:]
        var cameras = "# Camera list with one line of data per camera:\n#   CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]\n"
        var images = "# Image list with two lines of data per image:\n#   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME\n#   POINTS2D[] as (X, Y, POINT3D_ID)\n"
        for (i, frame) in manifest.frames.enumerated() {
            let k = frame.intrinsics
            let cid: Int
            if let existing = cameraIDs[k] {
                cid = existing
            } else {
                cid = cameraIDs.count + 1
                cameraIDs[k] = cid
                cameras += "\(cid) PINHOLE \(k.width) \(k.height) \(k.fx) \(k.fy) \(k.cx) \(k.cy)\n"
            }
            let p = colmapPose(frame.pose)
            let name = (frame.file as NSString).lastPathComponent
            images += "\(i + 1) \(p.rotation.w) \(p.rotation.x) \(p.rotation.y) \(p.rotation.z) "
                + "\(p.translation.x) \(p.translation.y) \(p.translation.z) \(cid) \(name)\n\n"
        }
        let points = "# 3D point list with one line of data per point:\n#   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)\n"
        return (cameras, images, points)
    }

    /// Nerfstudio-style `transforms.json` (camera→world, OpenGL axes — the same as ARKit).
    public static func transformsJSON(_ manifest: CaptureManifest) throws -> Data {
        struct Frame: Encodable {
            var file_path: String
            var transform_matrix: [[Float]]
            var fl_x, fl_y, cx, cy: Float
            var w, h: Int
        }
        struct Root: Encodable {
            var camera_model = "OPENCV"
            var frames: [Frame]
        }
        let frames = manifest.frames.map { f -> Frame in
            let p = f.pose
            let m: [[Float]] = [
                [p.right.x, p.up.x, p.back.x, p.position.x],
                [p.right.y, p.up.y, p.back.y, p.position.y],
                [p.right.z, p.up.z, p.back.z, p.position.z],
                [0, 0, 0, 1]
            ]
            let k = f.intrinsics
            return Frame(file_path: f.file, transform_matrix: m, fl_x: k.fx, fl_y: k.fy, cx: k.cx, cy: k.cy, w: k.width, h: k.height)
        }
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(Root(frames: frames))
    }
}
