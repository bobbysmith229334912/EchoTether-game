// MediaUploadService_NoAuth.swift
// EchoTether — No-login uploads for images + VIDEO + AUDIO + attachment doc creation

import Foundation
import AVFoundation
import UIKit
import FirebaseStorage
import FirebaseFirestore
import FirebaseFirestoreSwift

enum MediaUploadError: Error {
    case invalidInput
    case exportFailed
    case thumbnailFailed
}

final class MediaUploadService {
    static let shared = MediaUploadService()
    private init() {}

    private var storage: Storage { Storage.storage() }
    private var db: Firestore { Firestore.firestore() }

    // MARK: - Public APIs (IMAGE)

    /// Upload compressed JPEG image data and create an attachment doc.
    @discardableResult
    func uploadImageData(_ data: Data,
                         whisperId: String,
                         ownerId: String) async throws -> Attachment {
        guard !data.isEmpty else { throw MediaUploadError.invalidInput }

        let uuid = UUID().uuidString
        let path = "whispers/\(whisperId)/media/\(uuid).jpg"
        let ref = storage.reference(withPath: path)

        let meta = StorageMetadata()
        meta.contentType = "image/jpeg"

        _ = try await ref.putDataAsync(data, metadata: meta)
        let url = try await ref.downloadURL()

        // Optional: image dims
        var width: Int? = nil
        var height: Int? = nil
        if let img = UIImage(data: data) {
            width = Int(img.size.width)
            height = Int(img.size.height)
        }

        let att = Attachment(
            ownerUid: ownerId,
            kind: .image,
            url: url,
            thumbUrl: nil,
            storagePath: path,
            width: width,
            height: height,
            durationSec: nil,
            bytes: data.count
        )

        return try await createAttachmentDoc(att, whisperId: whisperId)
    }

    // MARK: - Public APIs (VIDEO)

    /// Compress, upload video + thumbnail, and create an attachment doc.
    /// - Parameter fileURL: local URL of the picked/recorded video (MOV/MP4)
    @discardableResult
    func uploadVideo(at fileURL: URL,
                     whisperId: String,
                     ownerId: String,
                     maxExportBitrate: Int = 3_000_000,  // ~3 Mbps
                     maxDimension: CGFloat = 1080) async throws -> Attachment {

        // 1) Export to H.264 .mp4 at reasonable size/bitrate
        let exportURL = try await exportCompressedMP4(
            from: fileURL,
            maxBitrate: maxExportBitrate,
            maxDimension: maxDimension
        )

        // 2) Extract duration + thumbnail (and dims from thumbnail)
        let asset = AVURLAsset(url: exportURL)
        let durationTime = try await asset.load(.duration)
        let durationSec = CMTimeGetSeconds(durationTime)

        guard let thumbnail = try? await generateThumbnail(url: exportURL, at: .zero) else {
            throw MediaUploadError.thumbnailFailed
        }
        let thumbJPEG = thumbnail.jpegData(compressionQuality: 0.8) ?? Data()
        let width = Int(thumbnail.size.width)
        let height = Int(thumbnail.size.height)

        // 3) Upload video
        let videoUUID = UUID().uuidString
        let videoPath = "whispers/\(whisperId)/media/\(videoUUID).mp4"
        let videoRef = storage.reference(withPath: videoPath)

        let vMeta = StorageMetadata()
        vMeta.contentType = "video/mp4"

        _ = try await videoRef.putFileAsync(from: exportURL, metadata: vMeta)
        let videoURL = try await videoRef.downloadURL()

        // 4) Upload thumbnail
        let thumbUUID = UUID().uuidString
        let thumbPath = "whispers/\(whisperId)/media/\(thumbUUID).jpg"
        let thumbRef = storage.reference(withPath: thumbPath)

        let tMeta = StorageMetadata()
        tMeta.contentType = "image/jpeg"

        _ = try await thumbRef.putDataAsync(thumbJPEG, metadata: tMeta)
        let thumbURL = try await thumbRef.downloadURL()

        // 5) Build attachment (use file attributes for bytes)
        let exportedBytes = (try? FileManager.default
            .attributesOfItem(atPath: exportURL.path)[.size] as? NSNumber)?.intValue ?? 0

        let att = Attachment(
            ownerUid: ownerId,
            kind: .video,
            url: videoURL,
            thumbUrl: thumbURL,
            storagePath: videoPath,
            width: width,
            height: height,
            durationSec: durationSec,
            bytes: exportedBytes
        )

        // 6) Save doc
        let saved = try await createAttachmentDoc(att, whisperId: whisperId)

        // 7) Cleanup exported temp
        try? FileManager.default.removeItem(at: exportURL)

        return saved
    }

    // MARK: - Public APIs (AUDIO) — uses .video as a temporary kind to avoid enum errors

    /// Upload an audio whisper (.m4a) and create an attachment doc.
    /// NOTE: AttachmentKind.audio does NOT exist in your codebase yet.
    /// To keep this compiling, we tag it as `.video` for now and set contentType to "audio/m4a".
    /// Later, when you add `case audio` to AttachmentKind, change the line marked BELOW.
    @discardableResult
    func uploadAudio(at fileURL: URL,
                     whisperId: String,
                     ownerId: String) async throws -> Attachment {

        // 1) Inspect local file
        let asset = AVURLAsset(url: fileURL)
        let durationTime = try await asset.load(.duration)
        let durationSec = CMTimeGetSeconds(durationTime)

        let bytes = (try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue ?? 0

        // 2) Upload to Storage
        let uuid = UUID().uuidString
        let path = "whispers/\(whisperId)/media/\(uuid).m4a"
        let ref = storage.reference(withPath: path)

        let meta = StorageMetadata()
        meta.contentType = "audio/m4a"

        _ = try await ref.putFileAsync(from: fileURL, metadata: meta)
        let url = try await ref.downloadURL()

        // 3) Build attachment (no dims for audio; duration + bytes included)
        let att = Attachment(
            ownerUid: ownerId,
            kind: .video,          // ← TEMPORARY: use `.video` to avoid enum compile error
            // When you add AttachmentKind.audio, change to: kind: .audio,
            url: url,
            thumbUrl: nil,
            storagePath: path,
            width: nil,
            height: nil,
            durationSec: durationSec,
            bytes: bytes
        )

        // 4) Save doc
        return try await createAttachmentDoc(att, whisperId: whisperId)
    }

    // MARK: - Private (Firestore)

    private func createAttachmentDoc(_ att: Attachment, whisperId: String) async throws -> Attachment {
        let col = db.collection("whispers").document(whisperId).collection("attachments")
        let doc = col.document()
        var enc = try Firestore.Encoder().encode(att)
        enc["createdAt"] = FieldValue.serverTimestamp()
        try await doc.setData(enc, merge: false)

        var saved = att
        saved.id = doc.documentID
        return saved
    }

    // MARK: - Private (Video utils)

    private func exportCompressedMP4(from url: URL,
                                     maxBitrate: Int,
                                     maxDimension: CGFloat) async throws -> URL {
        let asset = AVURLAsset(url: url)

        let preset = AVAssetExportPreset1920x1080
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaUploadError.exportFailed
        }

        // Output
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        session.outputURL = outURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        // Downscale if needed
        if let vt = try await asset.loadTracks(withMediaType: .video).first {
            let naturalSize = try await vt.load(.naturalSize)
            let maxSide = max(naturalSize.width, naturalSize.height)
            if maxSide > maxDimension {
                let scale = maxDimension / maxSide
                let newW = Int(naturalSize.width * scale)
                let newH = Int(naturalSize.height * scale)

                let composition = AVMutableVideoComposition()
                composition.renderSize = CGSize(width: newW, height: newH)
                composition.frameDuration = CMTime(value: 1, timescale: 30)

                let instruction = AVMutableVideoCompositionInstruction()
                let duration = try await asset.load(.duration)
                instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: vt)
                let preferredTransform = try await vt.load(.preferredTransform)
                layerInstruction.setTransform(preferredTransform.scaledBy(x: scale, y: scale), at: .zero)

                instruction.layerInstructions = [layerInstruction]
                composition.instructions = [instruction]
                session.videoComposition = composition
            }
        }

        // ---- Export (iOS 18+ vs earlier) ----
        if #available(iOS 18.0, *) {
            try await session.export(to: outURL, as: .mp4)
        } else {
            await session.export()
            guard session.status == .completed else {
                throw MediaUploadError.exportFailed
            }
        }

        // Verify file exists and has non-zero size
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: outURL.path, isDirectory: &isDir)
        let size = (try? FileManager.default
            .attributesOfItem(atPath: outURL.path)[.size] as? NSNumber)?.intValue ?? 0

        guard exists, !isDir.boolValue, size > 0 else {
            throw MediaUploadError.exportFailed
        }

        return outURL
    }

    /// Generate a single thumbnail at `time`.
    private func generateThumbnail(url: URL, at time: CMTime) async throws -> UIImage {
        return try await withCheckedThrowingContinuation { cont in
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 1024, height: 1024)

            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgimg, _, result, error in
                if let cg = cgimg, error == nil, result == .succeeded {
                    cont.resume(returning: UIImage(cgImage: cg))
                } else {
                    cont.resume(throwing: MediaUploadError.thumbnailFailed)
                }
            }
        }
    }
}
