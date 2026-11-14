import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a recording into JPEG frames, one every `interval` seconds.
/// A frame that looks the same as the frame before it is skipped.
enum FrameExporter {
    static func export(video: URL, interval: Double) async throws -> [URL] {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        let folder = video.deletingLastPathComponent()
            .appendingPathComponent(video.deletingPathExtension().lastPathComponent + " frames", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var seconds = Array(stride(from: 0, to: duration, by: interval))
        seconds.append(max(0, duration - 0.05)) // the last thing on screen
        let times = seconds.map { CMTime(seconds: $0, preferredTimescale: 600) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var urls: [URL] = []
        var previous: [UInt8]?
        for await result in generator.images(for: times) {
            guard let image = try? result.image else { continue }
            let thumb = thumbnail(image)
            if let previous, !differs(previous, thumb) { continue }
            previous = thumb
            let name = String(format: "%03d_%.1fs.jpg", urls.count + 1, result.requestedTime.seconds)
            let url = folder.appendingPathComponent(name)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            if CGImageDestinationFinalize(dest) { urls.append(url) }
        }
        return urls
    }

    private static let side = 64

    /// A 64×64 grayscale copy, enough to see a typed character or a moved pointer.
    private static func thumbnail(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)
            ctx?.interpolationQuality = .medium
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return pixels
    }

    /// Video compression adds small noise, so only a clear change in some pixel counts.
    private static func differs(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        zip(a, b).contains { abs(Int($0) - Int($1)) > 10 }
    }
}
