import XCTest
@testable import CaptureKit

final class CoverageTests: XCTestCase {
    private func orbitPose(azimuth: Float, elevation: Float, radius: Float = 0.6, center: Vec3 = .zero) -> CameraPose {
        let el = elevation * .pi / 180, az = azimuth * .pi / 180
        let eye = center + radius * Vec3(cos(el) * sin(az), sin(el), cos(el) * cos(az))
        return CameraPose.looking(from: eye, at: center)
    }

    func testSphericalAngles() {
        let a = CoverageMap.sphericalAngles(of: Vec3(0, 0, 1))
        XCTAssertEqual(a.elevation, 0, accuracy: 1e-4)
        XCTAssertEqual(a.azimuth, 0, accuracy: 1e-4)
        let b = CoverageMap.sphericalAngles(of: normalized(Vec3(-1, 1, 0)))
        XCTAssertEqual(b.elevation, 45, accuracy: 1e-3)
        XCTAssertEqual(b.azimuth, 270, accuracy: 1e-3)
    }

    func testOrbitCellAndRecording() {
        var map = CapturePlan.make(subject: .small, mode: .photos).makeCoverage(center: .zero)
        XCTAssertEqual(map.totalCells, 50)
        let pose = orbitPose(azimuth: 30, elevation: 30)
        XCTAssertEqual(map.cell(for: pose), CoverageCell(ring: 1, bin: 1))
        XCTAssertEqual(map.record(pose), CoverageCell(ring: 1, bin: 1))
        XCTAssertNil(map.record(pose), "second hit on the same cell is not new")
        XCTAssertEqual(map.coveredCells, 1)
        XCTAssertEqual(map.ringFraction(1), 1.0 / 18, accuracy: 1e-9)
    }

    func testRejectsBadAimAndDistance() {
        var map = CapturePlan.make(subject: .small, mode: .photos).makeCoverage(center: .zero)
        let away = CameraPose.looking(from: Vec3(0, 0, 0.6), at: Vec3(0, 0, 2))
        XCTAssertFalse(map.isValidViewpoint(away))
        XCTAssertNil(map.record(away))
        XCTAssertEqual(map.guidance(for: away), .aimAtSubject)
        XCTAssertEqual(map.guidance(for: orbitPose(azimuth: 0, elevation: 0, radius: 0.1)), .tooClose)
        XCTAssertEqual(map.guidance(for: orbitPose(azimuth: 0, elevation: 0, radius: 3)), .tooFar)
    }

    func testFullOrbitCompletes() {
        var map = CapturePlan.make(subject: .small, mode: .photos).makeCoverage(center: Vec3(1, 0, -2))
        for (r, ring) in map.rings.enumerated() {
            for bin in 0..<ring.bins {
                let pose = orbitPose(azimuth: ring.azimuth(ofBin: bin), elevation: min(ring.midElevation, 85), center: map.center)
                XCTAssertNotNil(map.record(pose), "ring \(r) bin \(bin)")
            }
        }
        XCTAssertEqual(map.fraction, 1)
        XCTAssertEqual(map.guidance(for: orbitPose(azimuth: 0, elevation: 0, center: map.center)), .complete)
    }

    func testOrbitGuidanceDirection() {
        var map = CapturePlan.make(subject: .small, mode: .photos).makeCoverage(center: .zero)
        // Cover the level ring except the bin centred at 97.5°, stand at 60°.
        let ring = map.rings[0]
        for bin in 0..<ring.bins where bin != 6 {
            map.record(orbitPose(azimuth: ring.azimuth(ofBin: bin), elevation: 0))
        }
        guard case .moveRight(let d) = map.guidance(for: orbitPose(azimuth: 60, elevation: 0)) else {
            return XCTFail("expected moveRight")
        }
        XCTAssertEqual(d, 37.5, accuracy: 0.01)
        guard case .moveLeft = map.guidance(for: orbitPose(azimuth: 130, elevation: 0)) else {
            return XCTFail("expected moveLeft")
        }
        map.record(orbitPose(azimuth: ring.azimuth(ofBin: 6), elevation: 0))
        XCTAssertEqual(map.guidance(for: orbitPose(azimuth: 60, elevation: 0)), .moveHigher(ring: "斜め上"))
    }

    /// Walking right around the subject (seen from the photographer) must increase azimuth.
    func testMoveRightMatchesCameraRight() {
        let pose = orbitPose(azimuth: 40, elevation: 0)
        let stepped = CameraPose.looking(from: pose.position + 0.05 * pose.right, at: .zero)
        let a0 = CoverageMap.sphericalAngles(of: normalized(pose.position)).azimuth
        let a1 = CoverageMap.sphericalAngles(of: normalized(stepped.position)).azimuth
        XCTAssertGreaterThan(a1, a0)
    }

    func testLookAroundGuidance() {
        var map = CapturePlan.make(subject: .space, mode: .video).makeCoverage(center: .zero)
        XCTAssertEqual(map.style, .lookAround)
        let facing = CameraPose.looking(from: .zero, at: Vec3(0, 0, 1))
        XCTAssertEqual(map.cell(for: facing)?.ring, 1)
        map.record(facing)
        let az = Float(352.5 * Double.pi / 180)
        map.record(CameraPose.looking(from: .zero, at: Vec3(sin(az), 0, cos(az))))
        // Nearest uncovered horizontal bin is now at 22.5° azimuth (+x side of +z); the camera's left is +x here.
        guard case .turnLeft = map.guidance(for: facing) else { return XCTFail("expected turnLeft") }
        XCTAssertEqual(facing.right.x, -1, accuracy: 1e-5)
    }

    func testWrappedDelta() {
        XCTAssertEqual(wrappedDelta(from: 350, to: 10), 20, accuracy: 1e-5)
        XCTAssertEqual(wrappedDelta(from: 10, to: 350), -20, accuracy: 1e-5)
    }
}

final class TriggerTests: XCTestCase {
    func testMotionEstimator() {
        var m = MotionEstimator(smoothing: 1)
        let a = CameraPose.looking(from: .zero, at: Vec3(0, 0, 1))
        let b = CameraPose.looking(from: Vec3(0.1, 0, 0), at: Vec3(0.1, 0, 1))
        m.update(a, time: 0)
        m.update(b, time: 0.5)
        XCTAssertEqual(m.linearSpeed, 0.2, accuracy: 1e-5)
        XCTAssertEqual(m.angularSpeed, 0, accuracy: 1e-2)
    }

    func testTriggerRules() {
        let plan = CapturePlan.make(subject: .small, mode: .photos)
        let map = plan.makeCoverage(center: .zero)
        var trigger = plan.makeTrigger()
        let still = MotionEstimator()
        let p0 = CameraPose.looking(from: Vec3(0, 0, 0.6), at: .zero)
        XCTAssertEqual(trigger.evaluate(pose: p0, time: 0, motion: still, trackingNormal: false, coverage: map), .trackingLimited)
        XCTAssertNil(trigger.evaluate(pose: p0, time: 0, motion: still, trackingNormal: true, coverage: map))
        trigger.didCapture(pose: p0, time: 0)
        XCTAssertEqual(trigger.evaluate(pose: p0, time: 0.1, motion: still, trackingNormal: true, coverage: map), .tooSoon)
        XCTAssertEqual(trigger.evaluate(pose: p0, time: 2, motion: still, trackingNormal: true, coverage: map), .notEnoughChange)
        let az = Float(12 * Double.pi / 180)
        let p1 = CameraPose.looking(from: 0.6 * Vec3(sin(az), 0, cos(az)), at: .zero)
        XCTAssertNil(trigger.evaluate(pose: p1, time: 2, motion: still, trackingNormal: true, coverage: map))

        var fast = MotionEstimator(smoothing: 1)
        fast.update(p0, time: 0)
        fast.update(p1, time: 0.1)
        XCTAssertEqual(trigger.evaluate(pose: p1, time: 2, motion: fast, trackingNormal: true, coverage: map), .movingTooFast)
    }
}

final class PlanTests: XCTestCase {
    func testRecommendations() {
        let small = CapturePlan.make(subject: .small, mode: .video)
        XCTAssertEqual(small.recommendedPhotoCount, 50...75)
        XCTAssertEqual(small.recommendedVideoSeconds, 90...126)
        XCTAssertTrue(small.tips.contains { $0.contains("90〜126 秒") })
        for s in SubjectSize.allCases {
            for m in CaptureMode.allCases {
                let p = CapturePlan.make(subject: s, mode: m)
                XCTAssertGreaterThan(p.totalCells, 0)
                XCTAssertLessThanOrEqual(p.recommendedPhotoCount.lowerBound, p.recommendedPhotoCount.upperBound)
                let covered = p.rings.map { ($0.minElevation, $0.maxElevation) }
                for i in 1..<covered.count { XCTAssertEqual(covered[i - 1].1, covered[i].0, "rings must be contiguous") }
            }
        }
    }
}

final class ExportTests: XCTestCase {
    private func manifest(_ poses: [CameraPose]) -> CaptureManifest {
        let k = CameraIntrinsics(fx: 1500, fy: 1500, cx: 960, cy: 720, width: 1920, height: 1440)
        return CaptureManifest(createdAt: Date(timeIntervalSince1970: 0), device: "test", subject: .small, mode: .photos,
                               center: .zero, coverage: 0.5,
                               frames: poses.enumerated().map { CapturedFrame(file: "images/frame_\($0.offset).jpg", time: Double($0.offset), pose: $0.element, intrinsics: k) })
    }

    func testColmapPoseProjectsCenterOnAxis() {
        let pose = CameraPose.looking(from: Vec3(0.3, 0.2, 0.5), at: Vec3(0, 0, 0))
        let p = PoseExport.colmapPose(pose)
        let q = p.rotation
        // Rotate the world origin into camera space using the quaternion and translation.
        let v = Vec3(0, 0, 0)
        let u = Vec3(q.x, q.y, q.z)
        let rotated = v + 2 * cross(u, cross(u, v) + q.w * v)
        let cam = rotated + p.translation
        XCTAssertEqual(cam.x, 0, accuracy: 1e-5)
        XCTAssertEqual(cam.y, 0, accuracy: 1e-5)
        XCTAssertEqual(cam.z, length(Vec3(0.3, 0.2, 0.5)), accuracy: 1e-5)
        // A point above the centre (world +y) must appear with negative image y (COLMAP y is down).
        let up = Vec3(0, 0.05, 0)
        let upCam = up + 2 * cross(u, cross(u, up) + q.w * up) + p.translation
        XCTAssertLessThan(upCam.y, 0)
        XCTAssertEqual(q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z, 1, accuracy: 1e-5)
    }

    func testQuaternionBranches() {
        // 180° about x, y, z exercise the non-trace branches.
        let cases: [(Vec3, Vec3, Vec3, Quaternion)] = [
            (Vec3(1, 0, 0), Vec3(0, -1, 0), Vec3(0, 0, -1), Quaternion(w: 0, x: 1, y: 0, z: 0)),
            (Vec3(-1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, -1), Quaternion(w: 0, x: 0, y: 1, z: 0)),
            (Vec3(-1, 0, 0), Vec3(0, -1, 0), Vec3(0, 0, 1), Quaternion(w: 0, x: 0, y: 0, z: 1))
        ]
        for (r0, r1, r2, expected) in cases {
            let q = PoseExport.quaternion(rows: r0, r1, r2)
            XCTAssertEqual(abs(q.x), expected.x, accuracy: 1e-5)
            XCTAssertEqual(abs(q.y), expected.y, accuracy: 1e-5)
            XCTAssertEqual(abs(q.z), expected.z, accuracy: 1e-5)
        }
    }

    func testColmapTextSharesCameras() {
        let m = manifest([CameraPose.looking(from: Vec3(0, 0, 1), at: .zero), CameraPose.looking(from: Vec3(1, 0, 0), at: .zero)])
        let t = PoseExport.colmapText(m)
        let camLines = t.cameras.split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(camLines, ["1 PINHOLE 1920 1440 1500.0 1500.0 960.0 720.0"])
        let imgLines = t.images.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        XCTAssertEqual(imgLines.count, 2)
        XCTAssertTrue(imgLines[1].hasSuffix(" 1 frame_1.jpg"))
        // ARKit camera at +z looking at the origin is COLMAP's identity camera rotated 180° about x.
        XCTAssertEqual(imgLines[0], "1 0.0 1.0 0.0 0.0 0.0 0.0 1.0 1 frame_0.jpg")
    }

    func testManifestRoundTripAndTransforms() throws {
        let m = manifest([CameraPose.looking(from: Vec3(0, 0, 1), at: .zero)])
        XCTAssertEqual(try CaptureManifest.decode(m.encoded()), m)
        let json = try JSONSerialization.jsonObject(with: PoseExport.transformsJSON(m)) as? [String: Any]
        let frames = json?["frames"] as? [[String: Any]]
        XCTAssertEqual(frames?.first?["file_path"] as? String, "images/frame_0.jpg")
        let matrix = frames?.first?["transform_matrix"] as? [[Double]]
        XCTAssertEqual(matrix?[2][3] ?? 0, 1, accuracy: 1e-6)
    }

    func testIntrinsicsScaling() {
        let k = CameraIntrinsics(fx: 1000, fy: 1000, cx: 960, cy: 720, width: 1920, height: 1440)
        let s = k.scaled(toWidth: 4032, height: 3024)
        XCTAssertEqual(s.fx, 2100, accuracy: 1e-2)
        XCTAssertEqual(s.fy, 2100, accuracy: 1e-2)
        XCTAssertEqual(s.cx, 2016, accuracy: 1e-2)
        XCTAssertEqual(s.cy, 1512, accuracy: 1e-2)
        XCTAssertEqual(s.width, 4032)
        XCTAssertEqual(s.height, 3024)
    }
}
