import AppKit
import Vision
import ImageIO
import CoreImage
import AVFoundation
import AlignmentCore

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Photo: Identifiable, Codable {
    var id = UUID()
    var filename: String
    var title: String
    var date: Date?
    var width: Int
    var height: Int
    var faces: [EyePair]
    var eyes: EyePair?
    var included = true
}

struct FilmSettings: Codable, Equatable {
    var portrait = true
    var seconds = 0.5
    var spacing = 0.28
    var eyeHeight = 0.62
    var fade = true
    var showDate = false
    var width: Int { portrait ? 1080 : 1920 }
    var height: Int { portrait ? 1920 : 1080 }
}

struct Project: Codable {
    var version = 1
    var photos: [Photo]
    var settings: FilmSettings
}

struct ImportSource {
    let url: URL
    var title: String? = nil
    var date: Date? = nil
}

struct ImportResult {
    var photos: [Photo] = []
    var failures: [String] = []
}

enum PhotoEngine {
    static let context = CIContext(options: [.cacheIntermediates: false])
    static func image(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary) else { throw AppError("写真を読み込めません: \(url.lastPathComponent)") }
        return image
    }

    static func captureDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let value = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let offset = exif["OffsetTimeOriginal"] as? String {
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ssXXXXX"
            return formatter.date(from: value + offset)
        }
        return formatter.date(from: value)
    }

    static func findEyes(_ image: CGImage) throws -> [EyePair] {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        return (request.results ?? []).sorted {
            $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height
        }.compactMap { face in
            guard let l = face.landmarks?.leftEye, let r = face.landmarks?.rightEye,
                  l.pointCount > 0, r.pointCount > 0 else { return nil }
            func center(_ region: VNFaceLandmarkRegion2D) -> Point {
                let points = region.normalizedPoints
                let x = points.reduce(CGFloat(0)) { $0 + $1.x } / CGFloat(points.count)
                let y = points.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(points.count)
                return Point(Double((face.boundingBox.minX + x * face.boundingBox.width) * CGFloat(image.width)),
                             Double((face.boundingBox.minY + y * face.boundingBox.height) * CGFloat(image.height)))
            }
            return EyePair(center(l), center(r))
        }
    }

    static func importPhotos(_ sources: [ImportSource], to directory: URL,
                             progress: @escaping (Int, Int) -> Void) throws -> ImportResult {
        var result = ImportResult()
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            autoreleasepool {
                do {
                    let image = try PhotoEngine.image(source.url)
                    let id = UUID()
                    let name = id.uuidString + ".jpg"
                    let url = directory.appendingPathComponent(name)
                    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
                        throw AppError("作業用写真を保存できません。")
                    }
                    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
                    guard CGImageDestinationFinalize(destination) else { throw AppError("写真の保存に失敗しました。") }
                    // Failed detection still leaves the image available for manual eye selection.
                    let faces = (try? findEyes(image)) ?? []
                    result.photos.append(Photo(id: id, filename: name,
                        title: source.title ?? source.url.lastPathComponent,
                        date: source.date ?? captureDate(source.url), width: image.width, height: image.height,
                        faces: faces, eyes: faces.count == 1 ? faces.first : nil))
                } catch { result.failures.append("\(source.title ?? source.url.lastPathComponent): \(error.localizedDescription)") }
            }
            progress(index + 1, sources.count)
        }
        return result
    }

    static func render(_ photo: Photo, directory: URL, settings: FilmSettings,
                       width: Int? = nil, height: Int? = nil) throws -> CGImage {
        let w = width ?? settings.width, h = height ?? settings.height
        guard let eyes = photo.eyes,
              let t = Similarity.align(eyes, width: Double(w), height: Double(h),
                                       eyeSpacing: settings.spacing, eyeHeight: settings.eyeHeight) else {
            throw AppError("\(photo.title) の両目を指定してください。")
        }
        let cg = try image(directory.appendingPathComponent(photo.filename))
        let ci = CIImage(cgImage: cg).transformed(by: CGAffineTransform(a: t.a, b: t.b, c: -t.b, d: t.a, tx: t.tx, ty: t.ty))
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let background = CIImage(color: CIColor(red: 0.035, green: 0.04, blue: 0.06)).cropped(to: rect)
        guard let rendered = context.createCGImage(ci.composited(over: background).cropped(to: rect), from: rect) else {
            throw AppError("画像を描画できません。")
        }
        guard settings.showDate, let date = photo.date else { return rendered }
        guard let canvas = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppError("日付の描画に失敗しました。")
        }
        canvas.draw(rendered, in: rect)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy.MM.dd"
        let font = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(w) * 0.035, weight: .medium)
        let text = formatter.string(from: date) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attrs)
        let padding = CGFloat(w) * 0.02
        let box = CGRect(x: CGFloat(w) * 0.05, y: CGFloat(h) * 0.05,
                         width: size.width + 2 * padding, height: size.height + padding)
        canvas.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        canvas.fill(box)
        text.draw(at: CGPoint(x: box.minX + padding, y: box.minY + padding / 2), withAttributes: attrs)
        guard let result = canvas.makeImage() else { throw AppError("日付の描画に失敗しました。") }
        return result
    }
}

enum MovieExporter {
    static func export(photos: [Photo], directory: URL, settings: FilmSettings, to url: URL,
                       progress: @escaping (Double) -> Void) async throws {
        guard !photos.isEmpty else { throw AppError("写真を追加してください。") }
        let w = settings.width, h = settings.height
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw AppError("動画エンコーダーを初期化できません。") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AppError("動画保存を開始できません。") }
        writer.startSession(atSourceTime: .zero)
        let framesPerPhoto = max(3, Int((settings.seconds * 30).rounded()))
        let total = photos.count * framesPerPhoto
        var previous: CGImage?
        do {
            for (index, photo) in photos.enumerated() {
                try Task.checkCancellation()
                let current = try PhotoEngine.render(photo, directory: directory, settings: settings)
                for f in 0..<framesPerPhoto {
                    try Task.checkCancellation()
                    let deadline = Date().addingTimeInterval(30)
                    while !input.isReadyForMoreMediaData {
                        try Task.checkCancellation()
                        guard writer.status == .writing else { throw writer.error ?? AppError("動画保存が停止しました。") }
                        guard Date() < deadline else { throw AppError("動画エンコーダーが応答しません。") }
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                    try autoreleasepool {
                        var buffer: CVPixelBuffer?
                        guard let pool = adaptor.pixelBufferPool,
                              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                              let buffer else { throw AppError("動画用メモリを確保できません。写真数を減らしてお試しください。") }
                        CVPixelBufferLockBaseAddress(buffer, [])
                        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                        guard let canvas = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
                            throw AppError("動画フレームを作成できません。")
                        }
                        let rect = CGRect(x: 0, y: 0, width: w, height: h)
                        let fadeFrames = max(1, framesPerPhoto / 3)
                        if settings.fade, let previous, f < fadeFrames {
                            canvas.draw(previous, in: rect)
                            canvas.setAlpha(CGFloat(f + 1) / CGFloat(fadeFrames))
                        }
                        canvas.draw(current, in: rect)
                        let frameIndex = index * framesPerPhoto + f
                        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frameIndex), timescale: 30)) else {
                            throw writer.error ?? AppError("動画フレームの保存に失敗しました。")
                        }
                    }
                    if f == framesPerPhoto - 1 { progress(Double(index + 1) / Double(photos.count)) }
                }
                previous = current
            }
            writer.endSession(atSourceTime: CMTime(value: Int64(total), timescale: 30))
            input.markAsFinished()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                writer.finishWriting { continuation.resume() }
            }
            guard writer.status == .completed else { throw writer.error ?? AppError("動画の仕上げに失敗しました。") }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
