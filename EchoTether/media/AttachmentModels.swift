// AttachmentModels.swift
// EchoTether – Media attachments model (images & videos)

import Foundation
import FirebaseFirestore
import FirebaseFirestoreSwift

public enum AttachmentKind: String, Codable, CaseIterable {
    case image
    case video
}

public struct Attachment: Identifiable, Codable, Hashable {
    /// Firestore doc id (whispers/{whisperId}/attachments/{id})
    @DocumentID public var id: String?

    /// Owner of the whisper/attachment (uid)
    public var ownerUid: String

    /// .image or .video
    public var kind: AttachmentKind

    /// Full https URL to the media (Firebase Storage download URL)
    public var url: URL

    /// Optional thumbnail URL (image or extracted video frame)
    public var thumbUrl: URL?

    /// Storage path (e.g. "whispers/WHISPER_ID/media/UUID.jpg")
    public var storagePath: String

    /// Pixel size (optional, nice for layout)
    public var width: Int?
    public var height: Int?

    /// Video-only metadata (seconds)
    public var durationSec: Double?

    /// Approx file size in bytes (helps with quotas/analytics)
    public var bytes: Int?

    /// Server timestamp when created
    @ServerTimestamp public var createdAt: Date?

    public init(
        id: String? = nil,
        ownerUid: String,
        kind: AttachmentKind,
        url: URL,
        thumbUrl: URL? = nil,
        storagePath: String,
        width: Int? = nil,
        height: Int? = nil,
        durationSec: Double? = nil,
        bytes: Int? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.ownerUid = ownerUid
        self.kind = kind
        self.url = url
        self.thumbUrl = thumbUrl
        self.storagePath = storagePath
        self.width = width
        self.height = height
        self.durationSec = durationSec
        self.bytes = bytes
        self.createdAt = createdAt
    }

    // Convenience
    public var isVideo: Bool { kind == .video }
    public var isImage: Bool { kind == .image }
}
