import Foundation

/// Smoothed camera speed estimate from successive poses.
public struct MotionEstimator: Sendable, Equatable {
    public private(set) var linearSpeed: Float = 0
    public private(set) var angularSpeed: Float = 0
    private var last: (pose: CameraPose, time: Double)?
    /// Exponential smoothing factor per update (0 = frozen, 1 = no smoothing).
    public var smoothing: Float

    public init(smoothing: Float = 0.3) {
        self.smoothing = smoothing
    }

    public static func == (a: MotionEstimator, b: MotionEstimator) -> Bool {
        a.linearSpeed == b.linearSpeed && a.angularSpeed == b.angularSpeed && a.last?.time == b.last?.time
    }

    public mutating func update(_ pose: CameraPose, time: Double) {
        defer { last = (pose, time) }
        guard let last, time > last.time else { return }
        let dt = Float(time - last.time)
        let v = length(pose.position - last.pose.position) / dt
        let w = angleBetween(pose.forward, last.pose.forward) / dt
        linearSpeed += smoothing * (v - linearSpeed)
        angularSpeed += smoothing * (w - angularSpeed)
    }

    public mutating func reset() {
        last = nil
        linearSpeed = 0
        angularSpeed = 0
    }
}

public enum CaptureBlocker: Equatable, Sendable {
    case trackingLimited
    case movingTooFast
    case tooSoon
    case notEnoughChange
    case invalidViewpoint
}

/// Decides when to take the next photo automatically.
public struct CaptureTrigger: Sendable, Equatable {
    /// Minimum change of viewpoint (degrees around the centre for orbits, view direction for look-around).
    public var angleStep: Float
    /// Alternative trigger: camera moved at least this far (metres) since the last capture.
    public var minTranslation: Float
    public var minInterval: Double
    /// Above these speeds images are likely blurred.
    public var maxAngularSpeed: Float
    public var maxLinearSpeed: Float
    public private(set) var lastCapture: (pose: CameraPose, time: Double)?

    public init(angleStep: Float, minTranslation: Float, minInterval: Double = 0.4,
                maxAngularSpeed: Float = 35, maxLinearSpeed: Float = 0.5) {
        self.angleStep = angleStep
        self.minTranslation = minTranslation
        self.minInterval = minInterval
        self.maxAngularSpeed = maxAngularSpeed
        self.maxLinearSpeed = maxLinearSpeed
    }

    public static func == (a: CaptureTrigger, b: CaptureTrigger) -> Bool {
        a.angleStep == b.angleStep && a.minTranslation == b.minTranslation && a.minInterval == b.minInterval
            && a.maxAngularSpeed == b.maxAngularSpeed && a.maxLinearSpeed == b.maxLinearSpeed
            && a.lastCapture?.time == b.lastCapture?.time && a.lastCapture?.pose == b.lastCapture?.pose
    }

    public func isTooFast(_ motion: MotionEstimator) -> Bool {
        motion.angularSpeed > maxAngularSpeed || motion.linearSpeed > maxLinearSpeed
    }

    /// Returns nil if a photo should be captured now, otherwise the reason it should not.
    public func evaluate(pose: CameraPose, time: Double, motion: MotionEstimator, trackingNormal: Bool,
                         coverage: CoverageMap) -> CaptureBlocker? {
        guard trackingNormal else { return .trackingLimited }
        guard coverage.isValidViewpoint(pose) else { return .invalidViewpoint }
        if isTooFast(motion) { return .movingTooFast }
        guard let last = lastCapture else { return nil }
        if time - last.time < minInterval { return .tooSoon }
        let moved = length(pose.position - last.pose.position)
        let turned: Float
        switch coverage.style {
        case .orbit:
            turned = angleBetween(pose.position - coverage.center, last.pose.position - coverage.center)
        case .lookAround:
            turned = angleBetween(pose.forward, last.pose.forward)
        }
        return turned >= angleStep || moved >= minTranslation ? nil : .notEnoughChange
    }

    public mutating func didCapture(pose: CameraPose, time: Double) {
        lastCapture = (pose, time)
    }

    public mutating func reset() {
        lastCapture = nil
    }
}
