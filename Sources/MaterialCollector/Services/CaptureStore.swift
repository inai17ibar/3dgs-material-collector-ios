import CaptureKit
import Foundation

/// One capture folder in Documents/Captures (visible in the Files app and Finder).
struct CaptureFolder: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var images: URL { url.appendingPathComponent("images", isDirectory: true) }
    var video: URL { url.appendingPathComponent("video.mov") }
    var manifestURL: URL { url.appendingPathComponent("manifest.json") }

    func manifest() -> CaptureManifest? {
        (try? Data(contentsOf: manifestURL)).flatMap { try? CaptureManifest.decode($0) }
    }

    var imageFiles: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: images, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var hasVideo: Bool { FileManager.default.fileExists(atPath: video.path) }
}

enum CaptureStore {
    static var root: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Captures", isDirectory: true)
    }

    static func makeFolder(subject: SubjectSize, date: Date = Date()) throws -> CaptureFolder {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let folder = CaptureFolder(url: root.appendingPathComponent("\(f.string(from: date))-\(subject.rawValue)", isDirectory: true))
        try FileManager.default.createDirectory(at: folder.images, withIntermediateDirectories: true)
        return folder
    }

    static func list() -> [CaptureFolder] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return urls.filter { $0.hasDirectoryPath }.map(CaptureFolder.init).sorted { $0.name > $1.name }
    }

    static func delete(_ folder: CaptureFolder) {
        try? FileManager.default.removeItem(at: folder.url)
    }

    /// Writes manifest.json, transforms.json and (for photos) a COLMAP text model under sparse/0.
    static func finalize(_ folder: CaptureFolder, manifest: CaptureManifest) throws {
        try manifest.encoded().write(to: folder.manifestURL, options: .atomic)
        let photoFrames = manifest.frames.filter { $0.file.hasPrefix("images/") }
        guard !photoFrames.isEmpty else { return }
        var photos = manifest
        photos.frames = photoFrames
        try PoseExport.transformsJSON(photos).write(to: folder.url.appendingPathComponent("transforms.json"), options: .atomic)
        let sparse = folder.url.appendingPathComponent("sparse/0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        let model = PoseExport.colmapText(photos)
        try model.cameras.write(to: sparse.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        try model.images.write(to: sparse.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)
        try model.points.write(to: sparse.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)
    }

    /// Zips the folder (via the file coordinator's upload representation) into a temporary file for sharing.
    static func zip(_ folder: CaptureFolder) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            var result: Result<URL, Error> = .failure(CocoaError(.fileWriteUnknown))
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: folder.url, options: .forUploading, error: &coordError) { zipURL in
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(folder.name).zip")
                do {
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: zipURL, to: dest)
                    result = .success(dest)
                } catch {
                    result = .failure(error)
                }
            }
            if let coordError { throw coordError }
            return try result.get()
        }.value
    }
}
