import CaptureKit
import SwiftUI

struct LibraryView: View {
    @State private var folders: [CaptureFolder] = []

    var body: some View {
        List {
            ForEach(folders) { folder in
                NavigationLink {
                    CaptureDetailView(folder: folder)
                } label: {
                    LibraryRow(folder: folder)
                }
            }
            .onDelete { offsets in
                offsets.map { folders[$0] }.forEach(CaptureStore.delete)
                folders.remove(atOffsets: offsets)
            }
        }
        .overlay {
            if folders.isEmpty {
                ContentUnavailableView("撮影データはまだありません", systemImage: "camera.metering.unknown")
            }
        }
        .navigationTitle("撮影データ")
        .onAppear { folders = CaptureStore.list() }
    }
}

private struct LibraryRow: View {
    let folder: CaptureFolder

    var body: some View {
        let manifest = folder.manifest()
        VStack(alignment: .leading, spacing: 4) {
            Text(folder.name).font(.headline)
            HStack(spacing: 10) {
                if let manifest {
                    Text(manifest.subject.displayName)
                    Text(manifest.mode == .video ? "動画" : "写真 \(folder.imageFiles.count) 枚")
                    Text("カバー率 \(Int((manifest.coverage * 100).rounded()))%")
                } else {
                    Text("保存が完了していません")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
