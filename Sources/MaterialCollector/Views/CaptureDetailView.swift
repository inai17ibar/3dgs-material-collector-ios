import CaptureKit
import ImageIO
import SwiftUI
import UIKit

struct CaptureDetailView: View {
    let folder: CaptureFolder
    @State private var zipURL: URL?
    @State private var zipping = false
    @State private var zipError: String?

    var body: some View {
        let manifest = folder.manifest()
        let images = folder.imageFiles
        List {
            Section("概要") {
                if let manifest {
                    LabeledContent("被写体", value: manifest.subject.displayName)
                    LabeledContent("撮影方法", value: manifest.mode.displayName)
                    LabeledContent("撮影位置のカバー率", value: "\(Int((manifest.coverage * 100).rounded()))%")
                    LabeledContent("撮影日時", value: manifest.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                if !images.isEmpty { LabeledContent("写真", value: "\(images.count) 枚") }
                if folder.hasVideo { LabeledContent("動画", value: "video.mov") }
                if let manifest, manifest.coverage < 0.8 {
                    Label("カバー率が低いと 3DGS に穴やぼやけが出やすくなります", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            Section {
                if let zipURL {
                    ShareLink(item: zipURL) {
                        Label("ZIP を共有（AirDrop など）", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button {
                        Task { await makeZip() }
                    } label: {
                        Label(zipping ? "ZIP を作成中…" : "ZIP を作成して共有", systemImage: "doc.zipper")
                    }
                    .disabled(zipping)
                }
                if folder.hasVideo {
                    ShareLink(item: folder.video) {
                        Label("動画だけを共有", systemImage: "film")
                    }
                }
                if let zipError { Text(zipError).foregroundStyle(.red).font(.caption) }
            } header: {
                Text("Mac に送る")
            } footer: {
                Text("Mac で ZIP を展開し、3DGS Composer の「写真を選択」で images フォルダを、「動画を選択」で video.mov を選んでください。manifest.json・transforms.json・sparse/0 には ARKit のカメラ位置が入っています。")
            }

            if !images.isEmpty {
                Section("写真") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 4)], spacing: 4) {
                        ForEach(images.prefix(120), id: \.self) { url in
                            Thumbnail(url: url)
                        }
                    }
                }
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func makeZip() async {
        zipping = true
        defer { zipping = false }
        do {
            zipURL = try await CaptureStore.zip(folder)
        } catch {
            zipError = "ZIP を作成できません: \(error.localizedDescription)"
        }
    }
}

private struct Thumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(.gray.opacity(0.2))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: url) {
                image = await Task.detached(priority: .utility) { [url] in Self.load(url) }.value
            }
    }

    private static func load(_ url: URL) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 200,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary).map { UIImage(cgImage: $0) }
    }
}
