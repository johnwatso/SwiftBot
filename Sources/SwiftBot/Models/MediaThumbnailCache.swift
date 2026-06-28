import AppKit
import AVFoundation
import CryptoKit
import Foundation

actor MediaThumbnailCache {
    private let fileManager = FileManager.default

    private func cacheDirectoryURL() -> URL {
        let url = SwiftBotStorage.folderURL().appendingPathComponent("media-thumbnails", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func thumbnailResponse(for item: MediaLibraryItem) async -> BinaryHTTPResponse? {
        let cacheURL = cachedThumbnailURL(for: item)
        if let data = try? Data(contentsOf: cacheURL) {
            return BinaryHTTPResponse(status: "200 OK", contentType: "image/jpeg", headers: ["Cache-Control": "public, max-age=300"], body: data)
        }

        guard let image = await generateThumbnail(for: item) else { return nil }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.78]) else {
            return nil
        }
        try? jpeg.write(to: cacheURL, options: .atomic)
        return BinaryHTTPResponse(status: "200 OK", contentType: "image/jpeg", headers: ["Cache-Control": "public, max-age=300"], body: jpeg)
    }

    func frameResponse(for item: MediaLibraryItem, atSeconds: Double) async -> BinaryHTTPResponse? {
        let cacheURL = cachedFrameURL(for: item, atSeconds: atSeconds)
        if let data = try? Data(contentsOf: cacheURL) {
            return BinaryHTTPResponse(status: "200 OK", contentType: "image/jpeg", headers: ["Cache-Control": "public, max-age=120"], body: data)
        }

        guard let image = await generateFrame(for: item, atSeconds: atSeconds) else { return nil }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else {
            return nil
        }
        try? jpeg.write(to: cacheURL, options: .atomic)
        return BinaryHTTPResponse(status: "200 OK", contentType: "image/jpeg", headers: ["Cache-Control": "public, max-age=120"], body: jpeg)
    }

    private func cachedThumbnailURL(for item: MediaLibraryItem) -> URL {
        let fingerprint = "\(item.absolutePath)|\(item.modifiedAt.timeIntervalSince1970)|\(item.sizeBytes)"
        let digest = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectoryURL().appendingPathComponent("\(digest).jpg")
    }

    private func cachedFrameURL(for item: MediaLibraryItem, atSeconds: Double) -> URL {
        let rounded = String(format: "%.1f", max(0, atSeconds))
        let fingerprint = "\(item.absolutePath)|\(item.modifiedAt.timeIntervalSince1970)|\(item.sizeBytes)|frame|\(rounded)"
        let digest = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = cacheDirectoryURL().appendingPathComponent("frames", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(digest).jpg")
    }

    private func generateThumbnail(for item: MediaLibraryItem) async -> NSImage? {
        let url = URL(fileURLWithPath: item.absolutePath)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)

        let time = CMTime(seconds: 2, preferredTimescale: 600)
        return await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { cgImage, _, error in
                guard let cgImage, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
            }
        }
    }

    private func generateFrame(for item: MediaLibraryItem, atSeconds: Double) async -> NSImage? {
        let url = URL(fileURLWithPath: item.absolutePath)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 420, height: 240)

        let time = CMTime(seconds: max(0, atSeconds), preferredTimescale: 600)
        return await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { cgImage, _, error in
                guard let cgImage, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
            }
        }
    }
}
