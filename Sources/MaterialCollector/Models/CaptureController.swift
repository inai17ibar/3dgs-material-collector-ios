import ARKit
import CaptureKit
import Observation
import RealityKit
import UIKit

enum CapturePhase: Equatable {
    case placing, capturing, saving, finished
}

struct ViewAngles: Equatable {
    var elevation: Float
    var azimuth: Float
}

/// Drives one capture: AR tracking, coverage bookkeeping, auto shutter / video recording and saving.
@MainActor
@Observable
final class CaptureController: NSObject, ARSessionDelegate {
    let plan: CapturePlan

    private(set) var phase: CapturePhase = .placing
    private(set) var coverage: CoverageMap?
    private(set) var guidance: GuidanceHint?
    private(set) var trackingMessage: String? = "カメラを準備中…"
    private(set) var tooFast = false
    private(set) var angles: ViewAngles?
    private(set) var photoCount = 0
    private(set) var startedAt: Date?
    private(set) var isRecording = false
    private(set) var recordingStartedAt: Date?
    private(set) var flash = false
    private(set) var folder: CaptureFolder?
    var errorMessage: String?
    var autoCapture = true
    var lockExposure = true

    @ObservationIgnored private weak var arView: ARView?
    @ObservationIgnored private var motion = MotionEstimator()
    @ObservationIgnored private var trigger: CaptureTrigger
    @ObservationIgnored private var frames: [CapturedFrame] = []
    @ObservationIgnored private let photoWriter = PhotoWriter()
    @ObservationIgnored private var recorder: VideoRecorder?
    @ObservationIgnored private var pendingWrites = 0
    @ObservationIgnored private var highResInFlight = false
    @ObservationIgnored private var useHighRes = false
    @ObservationIgnored private var trackingNormal = false
    @ObservationIgnored private var lastPose: CameraPose?
    @ObservationIgnored private var firstTimestamp: Double?
    @ObservationIgnored private var lastPoseSample: Double = 0
    @ObservationIgnored private var lastAngleUpdate: Double = 0
    @ObservationIgnored private var markers: [CoverageCell: ModelEntity] = [:]
    @ObservationIgnored private var markerAnchor: AnchorEntity?

    init(plan: CapturePlan) {
        self.plan = plan
        trigger = plan.makeTrigger()
        super.init()
    }

    // MARK: - Session

    func attach(_ view: ARView) {
        arView = view
        view.session.delegate = self
        view.renderOptions.insert(.disableMotionBlur)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.worldAlignment = .gravity
        if plan.mode == .photos, let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            config.videoFormat = format
            useHighRes = true
        }
        view.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func pause() {
        arView?.session.pause()
        setExposureLock(false)
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { process(frame) }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { errorMessage = "AR セッションエラー: \(message)" }
    }

    private func process(_ frame: ARFrame) {
        let pose = Self.pose(of: frame.camera)
        let time = frame.timestamp
        updateTracking(frame.camera.trackingState)
        motion.update(pose, time: time)
        lastPose = pose
        let fast = trigger.isTooFast(motion)
        if fast != tooFast { tooFast = fast }

        guard phase == .capturing, let map = coverage else { return }
        if time - lastAngleUpdate > 0.1, let a = map.angles(of: pose) {
            angles = ViewAngles(elevation: a.elevation, azimuth: a.azimuth)
            lastAngleUpdate = time
        }

        switch plan.mode {
        case .photos:
            if autoCapture,
               trigger.evaluate(pose: pose, time: time, motion: motion, trackingNormal: trackingNormal, coverage: map) == nil {
                capturePhoto(current: frame)
            }
        case .video:
            if isRecording, let recorder {
                recorder.append(PixelBufferBox(buffer: frame.capturedImage), timestamp: time)
                if trackingNormal, !fast, let newly = coverage?.record(pose) { markCovered(newly) }
                if time - lastPoseSample >= 0.1, let rel = recorder.relativeTime(time) {
                    frames.append(CapturedFrame(file: "video.mov", time: rel, pose: pose, intrinsics: Self.intrinsics(of: frame)))
                    lastPoseSample = time
                }
            }
        }

        let hint = coverage?.guidance(for: pose)
        if hint != guidance { guidance = hint }
    }

    private func updateTracking(_ state: ARCamera.TrackingState) {
        let message: String?
        switch state {
        case .normal:
            message = nil
        case .notAvailable:
            message = "トラッキングできません"
        case .limited(let reason):
            switch reason {
            case .initializing: message = "初期化中… 周りをゆっくり映してください"
            case .excessiveMotion: message = "動きが速すぎます。ゆっくり動かしてください"
            case .insufficientFeatures: message = "特徴が少ない場所です。模様のある明るい方へ向けてください"
            case .relocalizing: message = "位置を再取得中…"
            @unknown default: message = "トラッキングが不安定です"
            }
        }
        trackingNormal = message == nil
        if message != trackingMessage { trackingMessage = message }
    }

    // MARK: - Placement

    /// How far above the aimed surface point the subject centre sits.
    private var centerLift: Float {
        switch plan.subject {
        case .small: return 0.08
        case .medium: return 0.8
        case .space: return 0
        }
    }

    func placeCenter() {
        guard let arView, let pose = lastPose else { return }
        let center: Vec3
        switch plan.style {
        case .orbit:
            let point = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
            if let hit = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first {
                let c = hit.worldTransform.columns.3
                center = Vec3(c.x, c.y, c.z) + Vec3(0, centerLift, 0)
            } else {
                let d = (plan.distance.lowerBound + min(plan.distance.upperBound, plan.distance.lowerBound * 3)) / 2
                center = pose.position + pose.forward * d
            }
        case .lookAround:
            center = pose.position
        }
        do {
            folder = try CaptureStore.makeFolder(subject: plan.subject)
        } catch {
            errorMessage = "保存先を作成できません: \(error.localizedDescription)"
            return
        }
        coverage = plan.makeCoverage(center: center)
        let radius: Float
        switch plan.style {
        case .orbit:
            let d = simd_length(pose.position - center)
            radius = min(max(d, plan.distance.lowerBound), plan.distance.upperBound)
        case .lookAround:
            radius = 1.5
        }
        buildMarkers(center: center, radius: radius)
        trigger.reset()
        startedAt = Date()
        phase = .capturing
        if lockExposure { setExposureLock(true) }
    }

    func resetCenter() {
        guard phase == .capturing, frames.isEmpty else { return }
        if let folder { CaptureStore.delete(folder) }
        folder = nil
        coverage = nil
        guidance = nil
        angles = nil
        markerAnchor.map { arView?.scene.removeAnchor($0) }
        markerAnchor = nil
        markers = [:]
        phase = .placing
    }

    private func buildMarkers(center: Vec3, radius: Float) {
        guard let arView, let map = coverage else { return }
        markerAnchor.map { arView.scene.removeAnchor($0) }
        let anchor = AnchorEntity(world: center)
        let size = max(0.006, radius * 0.025)
        if plan.style == .orbit {
            let core = ModelEntity(mesh: .generateSphere(radius: size * 1.2), materials: [UnlitMaterial(color: .systemOrange)])
            anchor.addChild(core)
        }
        var built: [CoverageCell: ModelEntity] = [:]
        let mesh = MeshResource.generateSphere(radius: size)
        for (r, ring) in map.rings.enumerated() {
            for bin in 0..<ring.bins {
                let cell = CoverageCell(ring: r, bin: bin)
                let entity = ModelEntity(mesh: mesh, materials: [Self.pendingMaterial])
                entity.position = map.direction(of: cell) * radius
                anchor.addChild(entity)
                built[cell] = entity
            }
        }
        arView.scene.addAnchor(anchor)
        markerAnchor = anchor
        markers = built
    }

    private static let pendingMaterial = UnlitMaterial(color: UIColor.white.withAlphaComponent(0.55))
    private static let coveredMaterial = UnlitMaterial(color: .systemGreen)

    private func markCovered(_ cell: CoverageCell) {
        markers[cell]?.model?.materials = [Self.coveredMaterial]
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Photos

    func shutter() {
        guard phase == .capturing, plan.mode == .photos, let frame = arView?.session.currentFrame else { return }
        capturePhoto(current: frame)
    }

    private func capturePhoto(current frame: ARFrame) {
        guard folder != nil, !highResInFlight, pendingWrites < 3 else { return }
        trigger.didCapture(pose: Self.pose(of: frame.camera), time: frame.timestamp)
        guard useHighRes, let session = arView?.session else {
            store(frame)
            return
        }
        highResInFlight = true
        session.captureHighResolutionFrame { [weak self] highRes, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.highResInFlight = false
                    if let highRes {
                        self.store(highRes)
                    } else if let current = self.arView?.session.currentFrame {
                        self.store(current)
                    }
                }
            }
        }
    }

    private func store(_ frame: ARFrame) {
        guard let folder else { return }
        let pose = Self.pose(of: frame.camera)
        if firstTimestamp == nil { firstTimestamp = frame.timestamp }
        photoCount += 1
        let name = String(format: "frame_%05d.jpg", photoCount)
        frames.append(CapturedFrame(file: "images/\(name)", time: frame.timestamp - (firstTimestamp ?? frame.timestamp),
                                    pose: pose, intrinsics: Self.intrinsics(of: frame)))
        if let newly = coverage?.record(pose) { markCovered(newly) }
        flashShutter()
        pendingWrites += 1
        let box = PixelBufferBox(buffer: frame.capturedImage)
        let url = folder.images.appendingPathComponent(name)
        let writer = photoWriter
        Task {
            do {
                try await writer.writeJPEG(box, to: url)
            } catch {
                errorMessage = "写真を保存できません: \(error.localizedDescription)"
            }
            pendingWrites -= 1
        }
    }

    private func flashShutter() {
        flash = true
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            flash = false
        }
    }

    // MARK: - Video

    func toggleRecording() {
        guard phase == .capturing, plan.mode == .video else { return }
        if isRecording {
            finish()
            return
        }
        guard let folder, let frame = arView?.session.currentFrame else { return }
        let w = CVPixelBufferGetWidth(frame.capturedImage), h = CVPixelBufferGetHeight(frame.capturedImage)
        do {
            // Camera frames are landscape; the app runs in portrait, so tag the movie for upright playback.
            recorder = try VideoRecorder(url: folder.video, width: w, height: h, transform: CGAffineTransform(rotationAngle: .pi / 2))
            isRecording = true
            recordingStartedAt = Date()
        } catch {
            errorMessage = "録画を開始できません: \(error.localizedDescription)"
        }
    }

    // MARK: - Finish

    func finish() {
        guard phase == .capturing, let folder, let map = coverage else { return }
        phase = .saving
        let activeRecorder = recorder
        recorder = nil
        isRecording = false
        Task {
            if let activeRecorder, let error = await activeRecorder.finish() {
                errorMessage = "動画を保存できません: \(error.localizedDescription)"
            }
            for _ in 0..<100 where pendingWrites > 0 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            pause()
            let device = "\(UIDevice.current.model) / iOS \(UIDevice.current.systemVersion)"
            let manifest = CaptureManifest(createdAt: startedAt ?? Date(), device: device, subject: plan.subject, mode: plan.mode,
                                           center: map.center, coverage: map.fraction,
                                           video: folder.hasVideo ? "video.mov" : nil, frames: frames)
            do {
                try CaptureStore.finalize(folder, manifest: manifest)
            } catch {
                errorMessage = "保存に失敗しました: \(error.localizedDescription)"
            }
            phase = .finished
        }
    }

    /// Stops without saving; removes the folder if nothing was captured.
    func abandon() {
        let hadRecording = recorder != nil
        recorder = nil
        isRecording = false
        pause()
        if let folder, frames.isEmpty, !hadRecording {
            CaptureStore.delete(folder)
        } else if let folder, let map = coverage, phase == .capturing {
            let manifest = CaptureManifest(createdAt: startedAt ?? Date(), device: UIDevice.current.model, subject: plan.subject,
                                           mode: plan.mode, center: map.center, coverage: map.fraction,
                                           video: folder.hasVideo ? "video.mov" : nil, frames: frames)
            try? CaptureStore.finalize(folder, manifest: manifest)
        }
    }

    // MARK: - Camera

    private func setExposureLock(_ locked: Bool) {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if locked {
                if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            } else {
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            }
        } catch {
            errorMessage = "露出を固定できません: \(error.localizedDescription)"
        }
    }

    private static func pose(of camera: ARCamera) -> CameraPose {
        let t = camera.transform
        return CameraPose(columns: t.columns.0, t.columns.1, t.columns.2, t.columns.3)
    }

    private static func intrinsics(of frame: ARFrame) -> CameraIntrinsics {
        let k = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let base = CameraIntrinsics(fx: k[0][0], fy: k[1][1], cx: k[2][0], cy: k[2][1],
                                    width: Int(res.width), height: Int(res.height))
        let w = CVPixelBufferGetWidth(frame.capturedImage), h = CVPixelBufferGetHeight(frame.capturedImage)
        return w == base.width && h == base.height ? base : base.scaled(toWidth: w, height: h)
    }
}
