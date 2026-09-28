import ARKit
import CaptureKit
import SwiftUI

struct HomeView: View {
    @AppStorage("subject") private var subject: SubjectSize = .small
    @AppStorage("mode") private var mode: CaptureMode = .photos
    @State private var capturing = false

    private var plan: CapturePlan { CapturePlan.make(subject: subject, mode: mode) }
    private let arSupported = ARWorldTrackingConfiguration.isSupported

    var body: some View {
        NavigationStack {
            Form {
                Section("被写体") {
                    Picker("被写体", selection: $subject) {
                        ForEach(SubjectSize.allCases, id: \.self) { s in
                            VStack(alignment: .leading) {
                                Text(s.displayName)
                                Text(s.example).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(s)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("撮影方法") {
                    Picker("撮影方法", selection: $mode) {
                        ForEach(CaptureMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section("目安") {
                    LabeledContent("撮影位置", value: "\(plan.totalCells) か所（\(plan.rings.count) 段）")
                    switch mode {
                    case .photos:
                        LabeledContent("写真の枚数",
                                       value: "\(plan.recommendedPhotoCount.lowerBound)〜\(plan.recommendedPhotoCount.upperBound) 枚")
                    case .video:
                        LabeledContent("動画の長さ",
                                       value: "\(plan.recommendedVideoSeconds.lowerBound)〜\(plan.recommendedVideoSeconds.upperBound) 秒")
                        LabeledContent("動くペース", value: "1 秒に約 \(Int(plan.videoAngularSpeed))°")
                    }
                    if plan.style == .orbit {
                        LabeledContent("被写体との距離", value: Self.distanceText(plan.distance))
                    }
                }

                Section("コツ") {
                    ForEach(plan.tips, id: \.self) { tip in
                        Label(tip, systemImage: "lightbulb").font(.callout)
                    }
                }

                Section {
                    Button {
                        capturing = true
                    } label: {
                        Label("撮影を開始", systemImage: "camera.viewfinder")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .disabled(!arSupported)
                } footer: {
                    if arSupported {
                        Text("撮影データは「ファイル」アプリの「3DGS Material Collector」フォルダにも保存されます。Mac の 3DGS Composer で写真フォルダまたは video.mov を読み込んでください。")
                    } else {
                        Text("この端末は ARKit のワールドトラッキングに対応していません。")
                    }
                }
            }
            .navigationTitle("3DGS 撮影ガイド")
            .toolbar {
                NavigationLink {
                    LibraryView()
                } label: {
                    Label("撮影データ", systemImage: "folder")
                }
            }
            .fullScreenCover(isPresented: $capturing) {
                CaptureView(plan: plan)
            }
        }
    }

    static func distanceText(_ range: ClosedRange<Float>) -> String {
        func f(_ m: Float) -> String { m < 1 ? "\(Int((m * 100).rounded()))cm" : String(format: "%.1fm", m) }
        return "\(f(range.lowerBound))〜\(f(range.upperBound))"
    }
}
