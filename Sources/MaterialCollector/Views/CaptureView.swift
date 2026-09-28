import CaptureKit
import RealityKit
import SwiftUI

struct CaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var controller: CaptureController

    init(plan: CapturePlan) {
        _controller = State(initialValue: CaptureController(plan: plan))
    }

    private var plan: CapturePlan { controller.plan }

    var body: some View {
        ZStack {
            ARViewContainer(controller: controller).ignoresSafeArea()
            if controller.phase == .placing { reticle }
            if controller.flash {
                Color.white.opacity(0.35).ignoresSafeArea().allowsHitTesting(false)
            }
            VStack(spacing: 12) {
                topBar
                banner
                Spacer()
                bottomPanel
            }
            .padding()
            if controller.phase == .saving {
                ProgressView("保存中…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(isPresented: .constant(controller.phase == .finished)) {
            if let folder = controller.folder {
                NavigationStack {
                    CaptureDetailView(folder: folder)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("閉じる") { dismiss() }
                            }
                        }
                }
                .interactiveDismissDisabled()
            }
        }
        .alert("エラー", isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.errorMessage ?? "")
        }
        .statusBarHidden()
    }

    private var reticle: some View {
        Image(systemName: "plus.viewfinder")
            .font(.system(size: 56, weight: .thin))
            .foregroundStyle(.white)
            .shadow(radius: 3)
            .allowsHitTesting(false)
    }

    private var topBar: some View {
        HStack {
            Button {
                controller.abandon()
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.headline).padding(10).background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            if controller.phase == .capturing {
                statsView
            }
        }
    }

    private var statsView: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let start = plan.mode == .video ? controller.recordingStartedAt : controller.startedAt
            let seconds = start.map { Int(context.date.timeIntervalSince($0)) } ?? 0
            HStack(spacing: 12) {
                switch plan.mode {
                case .photos:
                    Label("\(controller.photoCount) / \(plan.recommendedPhotoCount.lowerBound)〜\(plan.recommendedPhotoCount.upperBound) 枚",
                          systemImage: "photo.on.rectangle")
                case .video:
                    Label("\(Self.clock(seconds)) / \(plan.recommendedVideoSeconds.lowerBound)〜\(plan.recommendedVideoSeconds.upperBound) 秒",
                          systemImage: controller.isRecording ? "record.circle.fill" : "record.circle")
                        .foregroundStyle(controller.isRecording ? .red : .primary)
                }
                Text("\(Int(((controller.coverage?.fraction ?? 0) * 100).rounded()))%").bold()
            }
            .font(.footnote.monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    @ViewBuilder
    private var banner: some View {
        let (text, color): (String, Color) = {
            if let t = controller.trackingMessage { return (t, .orange) }
            if controller.tooFast { return ("動きが速すぎます。ゆっくり動かしてください", .red) }
            switch controller.phase {
            case .placing:
                return plan.style == .orbit
                    ? ("被写体の置いてある面（足元）に照準を合わせて「中心に設定」を押してください", .blue)
                    : ("撮影したい空間の中央付近に立ち「ここから開始」を押してください", .blue)
            case .capturing:
                if plan.mode == .video && !controller.isRecording { return ("録画ボタンを押して撮影を始めてください", .blue) }
                if controller.guidance == .complete { return (GuidanceHint.complete.message + "。「完了」で保存します", .green) }
                return (controller.guidance?.message ?? "", .blue)
            case .saving, .finished:
                return ("", .clear)
            }
        }()
        if !text.isEmpty {
            Text(text)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(color.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
                .animation(.easeInOut(duration: 0.2), value: text)
        }
    }

    @ViewBuilder
    private var bottomPanel: some View {
        switch controller.phase {
        case .placing:
            Button {
                controller.placeCenter()
            } label: {
                Text(plan.style == .orbit ? "中心に設定" : "ここから開始")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.trackingMessage != nil)
        case .capturing:
            VStack(spacing: 12) {
                if let map = controller.coverage {
                    CoverageDial(map: map, angles: controller.angles)
                        .frame(width: 150, height: 150)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
                HStack(alignment: .center) {
                    leadingControl.frame(maxWidth: .infinity)
                    mainButton
                    Button("完了") { controller.finish() }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .disabled(plan.mode == .photos ? controller.photoCount == 0 : false)
                        .frame(maxWidth: .infinity)
                }
            }
        case .saving, .finished:
            EmptyView()
        }
    }

    @ViewBuilder
    private var leadingControl: some View {
        switch plan.mode {
        case .photos:
            Toggle(isOn: $controller.autoCapture) {
                Label("自動", systemImage: controller.autoCapture ? "bolt.fill" : "bolt.slash")
            }
            .toggleStyle(.button)
            .buttonStyle(.bordered)
        case .video:
            Button("中心を再設定") { controller.resetCenter() }
                .buttonStyle(.bordered)
                .disabled(controller.isRecording)
                .font(.caption)
        }
    }

    @ViewBuilder
    private var mainButton: some View {
        switch plan.mode {
        case .photos:
            Button {
                controller.shutter()
            } label: {
                Circle().fill(.white).frame(width: 66, height: 66)
                    .overlay(Circle().stroke(.black.opacity(0.2), lineWidth: 3).padding(4))
            }
        case .video:
            Button {
                controller.toggleRecording()
            } label: {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 70, height: 70)
                    RoundedRectangle(cornerRadius: controller.isRecording ? 6 : 30)
                        .fill(.red)
                        .frame(width: controller.isRecording ? 30 : 58, height: controller.isRecording ? 30 : 58)
                }
            }
        }
    }

    private static func clock(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
}

struct ARViewContainer: UIViewRepresentable {
    let controller: CaptureController

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
    }
}

/// Top-down map of the viewpoint rings. The photographer is always drawn at the bottom (orbit) or
/// facing up (look-around), so pending cells on the screen's right are to the photographer's right.
struct CoverageDial: View {
    let map: CoverageMap
    let angles: ViewAngles?

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2 - 6
            let ringCount = map.rings.count
            let band = outer / CGFloat(ringCount + 1)
            let userAz = angles?.azimuth ?? 0
            let base: Double = map.style == .orbit ? 90 : -90

            func radius(_ ring: Int) -> CGFloat { outer - band * (CGFloat(ring) + 0.5) }
            func screenAngle(_ az: Float) -> Double {
                base - Double(wrappedDelta(userAz, az))
            }
            func point(_ deg: Double, _ r: CGFloat) -> CGPoint {
                CGPoint(x: c.x + r * cos(deg * .pi / 180), y: c.y + r * sin(deg * .pi / 180))
            }

            for (r, ring) in map.rings.enumerated() {
                let span = 360 / Double(ring.bins)
                for bin in 0..<ring.bins {
                    let mid = screenAngle(ring.azimuth(ofBin: bin))
                    var path = Path()
                    let steps = 6
                    for i in 0...steps {
                        let a = mid - span / 2 + 1.5 + (span - 3) * Double(i) / Double(steps)
                        let p = point(a, radius(r))
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    let covered = map.isCovered(CoverageCell(ring: r, bin: bin))
                    ctx.stroke(path, with: .color(covered ? .green : .gray.opacity(0.45)),
                               style: StrokeStyle(lineWidth: band * 0.75, lineCap: .butt))
                }
            }

            if let angles {
                let ring = map.ringIndex(elevation: angles.elevation)
                let r = ring.map(radius) ?? (angles.elevation < (map.rings.first?.minElevation ?? 0) ? outer : band * 0.5)
                let p = point(base, r)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.orange))
                ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)), with: .color(.white), lineWidth: 2)
            }
        }
    }

    private func wrappedDelta(_ a: Float, _ b: Float) -> Float {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d >= 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}
