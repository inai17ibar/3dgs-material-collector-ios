import Foundation

public enum SubjectSize: String, CaseIterable, Codable, Sendable {
    case small, medium, space

    public var displayName: String {
        switch self {
        case .small: return "小物（〜40cm）"
        case .medium: return "人物・家具（〜2m）"
        case .space: return "部屋・屋外の空間"
        }
    }

    public var example: String {
        switch self {
        case .small: return "フィギュア、靴、食器、植木鉢など"
        case .medium: return "人、椅子、自転車、彫像など"
        case .space: return "室内、庭、店舗など（中から見回す）"
        }
    }
}

public enum CaptureMode: String, CaseIterable, Codable, Sendable {
    case photos, video

    public var displayName: String {
        switch self {
        case .photos: return "写真（自動シャッター）"
        case .video: return "動画"
        }
    }
}

/// Recommended capture parameters for a subject size and mode.
public struct CapturePlan: Sendable, Equatable, Codable {
    public var subject: SubjectSize
    public var mode: CaptureMode
    public var style: CoverageStyle
    public var rings: [CoverageRing]
    /// Recommended distance from the subject centre (orbit) in metres.
    public var distance: ClosedRange<Float>
    public var angleStep: Float
    public var minTranslation: Float
    /// Target speed while walking/turning for video, degrees per second.
    public var videoAngularSpeed: Float
    public var maxAngularSpeed: Float
    public var maxLinearSpeed: Float

    public static func make(subject: SubjectSize, mode: CaptureMode) -> CapturePlan {
        switch subject {
        case .small:
            return CapturePlan(
                subject: subject, mode: mode, style: .orbit,
                rings: [CoverageRing(name: "低い位置", minElevation: -20, maxElevation: 20, bins: 24),
                        CoverageRing(name: "斜め上", minElevation: 20, maxElevation: 50, bins: 18),
                        CoverageRing(name: "真上付近", minElevation: 50, maxElevation: 90, bins: 8)],
                distance: 0.2...1.2, angleStep: 10, minTranslation: 0.15,
                videoAngularSpeed: 12, maxAngularSpeed: 30, maxLinearSpeed: 0.3)
        case .medium:
            return CapturePlan(
                subject: subject, mode: mode, style: .orbit,
                rings: [CoverageRing(name: "腰の高さ", minElevation: -20, maxElevation: 15, bins: 24),
                        CoverageRing(name: "目線の上", minElevation: 15, maxElevation: 45, bins: 16),
                        CoverageRing(name: "見下ろし", minElevation: 45, maxElevation: 90, bins: 6)],
                distance: 0.8...6, angleStep: 8, minTranslation: 0.4,
                videoAngularSpeed: 10, maxAngularSpeed: 30, maxLinearSpeed: 0.6)
        case .space:
            return CapturePlan(
                subject: subject, mode: mode, style: .lookAround,
                rings: [CoverageRing(name: "下向き", minElevation: -60, maxElevation: -15, bins: 12),
                        CoverageRing(name: "水平", minElevation: -15, maxElevation: 15, bins: 24),
                        CoverageRing(name: "上向き", minElevation: 15, maxElevation: 60, bins: 12)],
                distance: 0...Float.greatestFiniteMagnitude, angleStep: 12, minTranslation: 0.3,
                videoAngularSpeed: 15, maxAngularSpeed: 35, maxLinearSpeed: 0.7)
        }
    }

    public var totalCells: Int { rings.reduce(0) { $0 + $1.bins } }

    /// From one photo per cell up to one photo per `angleStep` on the widest ring, scaled per ring by bin count.
    public var recommendedPhotoCount: ClosedRange<Int> {
        let widest = rings.map(\.bins).max() ?? 1
        let perWidestRing = Int((360 / angleStep).rounded(.up))
        let dense = rings.reduce(0) { $0 + perWidestRing * $1.bins / widest }
        return totalCells...max(dense, totalCells)
    }

    /// Time to sweep every ring once at the target speed, plus 20% for transitions.
    public var recommendedVideoSeconds: ClosedRange<Int> {
        let sweep = Float(rings.count) * 360 / videoAngularSpeed
        return Int((sweep * 1.0).rounded())...Int((sweep * 1.4).rounded())
    }

    public func makeCoverage(center: Vec3) -> CoverageMap {
        CoverageMap(style: style, center: center, rings: rings, distanceRange: distance)
    }

    public func makeTrigger() -> CaptureTrigger {
        CaptureTrigger(angleStep: angleStep, minTranslation: minTranslation,
                       maxAngularSpeed: maxAngularSpeed, maxLinearSpeed: maxLinearSpeed)
    }

    public var tips: [String] {
        var t: [String] = []
        switch style {
        case .orbit:
            t.append("被写体の周りをゆっくり一周し、低い位置 → 斜め上 → 真上付近の順に高さを変えて撮影します")
            t.append("被写体はできるだけ画面の中央に。距離は \(Self.format(distance.lowerBound))〜\(Self.format(distance.upperBound)) が目安です")
        case .lookAround:
            t.append("立ち位置を少しずつ変えながら、水平 → 上向き → 下向きの順に見回します")
            t.append("その場で回転するだけでは奥行きが推定できません。1 歩ずつ横に移動してください")
        }
        switch mode {
        case .photos:
            t.append("ブレないよう動きを止めた瞬間に自動で撮影します。目安は \(recommendedPhotoCount.lowerBound)〜\(recommendedPhotoCount.upperBound) 枚")
        case .video:
            t.append("1 秒に約 \(Int(videoAngularSpeed))° のペースで動くと、1 周 \(Int(360 / videoAngularSpeed)) 秒・全体で \(recommendedVideoSeconds.lowerBound)〜\(recommendedVideoSeconds.upperBound) 秒が目安です")
        }
        t.append("反射・透明な物、動く物は苦手です。明るさが一定の場所で撮影してください")
        return t
    }

    private static func format(_ m: Float) -> String {
        m < 1 ? "\(Int((m * 100).rounded()))cm" : String(format: "%.1fm", m)
    }
}
