//  ARWhisperView.swift
//  EchoTether
//
//  Fully rewritten to (1) start/stop LocationManager with the view,
//  (2) react to location updates so nearby whispers appear immediately,
//  (3) preserve your claim/password/sidebar/media flows,
//  (4) keep Firestore live updates and safe anchor placement.
//

import SwiftUI
import RealityKit
import ARKit
@preconcurrency import FirebaseFirestore
import FirebaseFirestoreSwift
import FirebaseAuth
import CoreLocation
import Combine
import UIKit
import AVFoundation
import AVKit
import CoreImage
import CryptoKit   // SHA-256

struct ARWhisperView: UIViewRepresentable {
    @EnvironmentObject var locationManager: LocationManager
    @Environment(\.presentationMode) var presentationMode

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ARView {
        // ✅ Ensure we’re receiving location updates while AR is onscreen
        locationManager.start()

        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false
        arView.session.delegate = context.coordinator
        context.coordinator.arView = arView

        // Configure AR (prefer Geo if supported + authorized)
        let lm = CLLocationManager()
        let auth: CLAuthorizationStatus
        if #available(iOS 14.0, *) { auth = lm.authorizationStatus } else { auth = CLLocationManager.authorizationStatus() }

        if #available(iOS 14.0, *),
           ARGeoTrackingConfiguration.isSupported,
           (auth == .authorizedWhenInUse || auth == .authorizedAlways) {
            let config = ARGeoTrackingConfiguration()
            config.planeDetection = [.horizontal]
            config.environmentTexturing = .automatic
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        } else {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal]
            config.worldAlignment = .gravity
            config.environmentTexturing = .automatic
            arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        }

        // Tap recognizer for media / info
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tap)

        // Sidebar toggle button
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 15.0, *) {
            var cfg = UIButton.Configuration.plain()
            cfg.image = UIImage(systemName: "sidebar.right")
            cfg.baseForegroundColor = .white
            cfg.background.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            cfg.cornerStyle = .fixed
            cfg.background.cornerRadius = 10
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
            button.configuration = cfg
        } else {
            button.setImage(UIImage(systemName: "sidebar.right"), for: .normal)
            button.tintColor = .white
            button.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            button.layer.cornerRadius = 10
            button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        }
        button.addTarget(context.coordinator, action: #selector(Coordinator.toggleSidebar), for: .touchUpInside)
        arView.addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: arView.safeAreaLayoutGuide.topAnchor, constant: 8),
            button.trailingAnchor.constraint(equalTo: arView.safeAreaLayoutGuide.trailingAnchor, constant: -8)
        ])
        context.coordinator.sidebarButton = button

        // Sidebar overlay
        context.coordinator.installSidebarUI(on: arView)

        // 🔄 Bind to location updates so we place/update anchors as soon as we get a fix
        context.coordinator.bindLocation()

        // 🔁 Firestore live listener
        context.coordinator.startListeningToWhispers()

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.stopListening()
        coordinator.unbindLocation()
        uiView.session.pause()
        // Optional: stop continuous updates when leaving AR
        coordinator.parent.locationManager.stop()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, ARSessionDelegate, ObservableObject {
        let parent: ARWhisperView
        weak var arView: ARView?

        // Location
        private var locCancellable: AnyCancellable?
        private var lastPlacedFix: CLLocation?

        // UI
        weak var sidebarButton: UIButton?
        private var scrimView: UIView?
        private var sidebarView: SidebarView?

        // Data & state
        private var dbListener: ListenerRegistration?
        private var whispers: [String: WhisperRenderable] = [:]
        private var anchorMap: [String: AnchorEntity] = [:]
        private var attachmentsByWhisper: [String: [Attachment]] = [:]
        private var loadedAttachmentFor: Set<String> = []
        private var isGeoLocalized = false

        // Meta caches
        private var namesById: [String: String] = [:]
        private var centsById: [String: Int] = [:]
        private var fetchInFlight: Set<String> = []

        // Media players
        private var players: [String: AVPlayer] = [:]

        // Layout
        private let cardSize: SIMD2<Float>     = [0.45, 0.45]
        private let cardHeight: Float          = 1.5
        private let imageSize: Float           = 0.30
        private let videoHeight: Float         = 0.36
        private let attachmentStep: Float      = 0.35

        init(_ parent: ARWhisperView) {
            self.parent = parent
            super.init()
        }

        deinit {
            dbListener?.remove()
            players.values.forEach { $0.pause() }
        }

        // MARK: - Location binding

        func bindLocation() {
            unbindLocation()
            locCancellable = parent.locationManager.$lastLocation
                .receive(on: DispatchQueue.main)
                .sink { [weak self] loc in
                    guard let self, let loc else { return }
                    // Only react when location is likely new enough to matter
                    let shouldRebuild: Bool = {
                        guard let prev = self.lastPlacedFix else { return true }
                        let moved = prev.distance(from: loc)
                        // Re-evaluate if we moved ~8m or more, or if the new fix is fresher/accurate
                        return moved >= 8 ||
                               loc.timestamp > prev.timestamp ||
                               (loc.horizontalAccuracy > 0 && loc.horizontalAccuracy < prev.horizontalAccuracy)
                    }()
                    if shouldRebuild {
                        self.lastPlacedFix = loc
                        self.reapplyPlacementNearUser()
                        self.rebuildSidebarIfVisible()
                    }
                }
        }

        func unbindLocation() {
            locCancellable?.cancel()
            locCancellable = nil
        }

        private func reapplyPlacementNearUser() {
            // Try to (re)place any known whispers we previously filtered by distance,
            // or those that were locked because we had no location yet.
            for (_, w) in whispers {
                if isUnlocked(w, user: parent.locationManager.lastLocation) {
                    placeOrUpdateWhisper(w)
                } else {
                    removeWhisperAnchor(id: w.id)
                }
            }
        }

        // MARK: - Safe Float Helpers

        private func fSafe(_ x: Float, min lo: Float, max hi: Float) -> Float {
            guard x.isFinite else { return lo }
            return max(lo, min(x, hi))
        }

        private func pSafe(_ p: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(p.x.isFinite ? p.x : 0, p.y.isFinite ? p.y : 0, p.z.isFinite ? p.z : 0)
        }

        private func rebuildSidebarIfVisible() {
            guard sidebarView?.isShown == true else { return }
            showSidebar()
        }

        // MARK: - Lock logic

        private func isUnlocked(_ w: WhisperRenderable, user: CLLocation?) -> Bool {
            guard Date() >= w.unlockAt else { return false }
            guard let user = user else { return false }
            let drop = CLLocation(latitude: w.latitude, longitude: w.longitude)
            let dist = user.distance(from: drop)
            guard dist.isFinite else { return false }
            return dist <= w.radiusMeters
        }

        // MARK: - Password (SHA-256 hex)

        private func sha256Hex(_ s: String) -> String {
            let data = Data(s.utf8)
            let hash = SHA256.hash(data: data)
            return hash.map { String(format: "%02x", $0) }.joined()
        }

        private func promptPasswordIfNeeded(for w: WhisperRenderable, completion: @escaping (Bool, String?) -> Void) {
            guard let arView else { completion(true, nil); return }
            guard let stored = w.passwordHash, !stored.isEmpty else { completion(true, nil); return }

            let alert = UIAlertController(title: "Enter Password", message: nil, preferredStyle: .alert)
            alert.addTextField { tf in
                tf.isSecureTextEntry = true
                tf.placeholder = "Password"
            }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { _ in completion(false, nil) }))
            alert.addAction(UIAlertAction(title: "Unlock", style: .default, handler: { [weak self] _ in
                let input = alert.textFields?.first?.text ?? ""
                let ok = self?.sha256Hex(input).caseInsensitiveCompare(stored) == .orderedSame
                if ok == true { completion(true, input) } else {
                    self?.toast("Incorrect password")
                    completion(false, nil)
                }
            }))
            arView.window?.rootViewController?.present(alert, animated: true)
        }

        // MARK: - Meta fetch (name + balanceCents)

        private func fetchMetaIfNeeded(for id: String) {
            guard namesById[id] == nil || centsById[id] == nil, !fetchInFlight.contains(id) else { return }
            fetchInFlight.insert(id)

            Firestore.firestore()
                .collection("whispers").document(id)
                .getDocument { [weak self] snap, err in
                    guard let self else { return }
                    self.fetchInFlight.remove(id)
                    guard err == nil, let data = snap?.data() else { return }

                    if let name = data["name"] as? String, !name.isEmpty {
                        self.namesById[id] = name
                    }
                    if let cents = (data["balanceCents"] as? NSNumber)?.intValue {
                        self.centsById[id] = max(0, cents)
                    }

                    self.rebuildSidebarIfVisible()
                    if let anchor = self.anchorMap[id], let w = self.whispers[id] {
                        self.updateLabelTitle(for: anchor, whisper: w)
                    }
                }
        }

        private func displayTitle(for id: String, w: WhisperRenderable) -> String {
            let title = (namesById[id]?.isEmpty == false) ? namesById[id]! : "Whisper"
            return "\(title) • \(currency(centsById[id], fallback: w.balance))"
        }

        // MARK: - Sidebar UI

        func installSidebarUI(on host: UIView) {
            let scrim = UIControl()
            scrim.translatesAutoresizingMaskIntoConstraints = false
            scrim.backgroundColor = UIColor.black.withAlphaComponent(0.0)
            scrim.addTarget(self, action: #selector(hideSidebar), for: .touchUpInside)
            host.addSubview(scrim)
            NSLayoutConstraint.activate([
                scrim.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                scrim.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                scrim.topAnchor.constraint(equalTo: host.topAnchor),
                scrim.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
            scrim.isHidden = true
            self.scrimView = scrim

            let panel = SidebarView()
            panel.translatesAutoresizingMaskIntoConstraints = false
            panel.isHidden = true
            host.addSubview(panel)

            let width: CGFloat = 280
            let trailing = panel.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: width)
            NSLayoutConstraint.activate([
                panel.widthAnchor.constraint(equalToConstant: width),
                panel.topAnchor.constraint(equalTo: host.topAnchor),
                panel.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                trailing
            ])
            panel.trailingConstraint = trailing

            panel.onOpen = { [weak self] wid in self?.openWhisperMedia(wid) }
            panel.onInfo = { [weak self] wid in self?.presentInfo(for: wid) }
            panel.onDelete = { [weak self] wid in
                guard let self, let w = self.whispers[wid] else { return }
                guard self.canDelete(w) else { self.toast("You can’t delete this."); return }
                self.confirmDelete(w)
            }

            self.sidebarView = panel
        }

        @objc func toggleSidebar() { sidebarView?.isShown == true ? hideSidebar() : showSidebar() }

        private func showSidebar() {
            guard let panel = sidebarView, let scrim = scrimView, let arView else { return }

            let items = whispers.keys.compactMap { wid -> SidebarItem? in
                guard let w = whispers[wid] else { return nil }
                guard isUnlocked(w, user: parent.locationManager.lastLocation) else { return nil }
                if attachmentsByWhisper[wid] == nil { loadAttachments(for: w) }
                fetchMetaIfNeeded(for: wid)
                let count = attachmentsByWhisper[wid]?.count ?? 0
                return SidebarItem(
                    id: wid,
                    title: displayTitle(for: wid, w: w),
                    subtitle: count > 0 ? "\(count) item\(count == 1 ? "" : "s")" : "Loading…",
                    canDelete: canDelete(w)
                )
            }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            panel.update(items: items)

            scrim.isHidden = false
            panel.isHidden = false
            arView.layoutIfNeeded()
            panel.trailingConstraint?.constant = 0
            UIView.animate(withDuration: 0.22) {
                scrim.backgroundColor = UIColor.black.withAlphaComponent(0.25)
                arView.layoutIfNeeded()
            }
            panel.isShown = true
        }

        @objc private func hideSidebar() {
            guard let panel = sidebarView, let scrim = scrimView, let arView else { return }
            panel.trailingConstraint?.constant = panel.bounds.width
            UIView.animate(withDuration: 0.2, animations: {
                scrim.backgroundColor = UIColor.black.withAlphaComponent(0.0)
                arView.layoutIfNeeded()
            }) { _ in
                panel.isHidden = true
                scrim.isHidden = true
            }
            panel.isShown = false
        }

        private func refreshSidebarRow(for wid: String) {
            guard let panel = sidebarView, panel.isShown,
                  let w = whispers[wid] else { return }
            guard isUnlocked(w, user: parent.locationManager.lastLocation) else {
                rebuildSidebarIfVisible()
                return
            }

            let count = attachmentsByWhisper[wid]?.count ?? 0
            fetchMetaIfNeeded(for: wid)
            panel.updateItem(id: wid,
                             subtitle: count > 0 ? "\(count) item\(count == 1 ? "" : "s")" : "Loading…",
                             canDelete: canDelete(w))
        }

        // MARK: - Firestore

        func startListeningToWhispers() {
            let db = Firestore.firestore()
            dbListener = db.collection("whispers")
                .whereField("deleted", isEqualTo: false)
                .whereField("unlockAt", isLessThanOrEqualTo: Timestamp(date: Date()))
                .addSnapshotListener { [weak self] snap, err in
                    guard let self else { return }
                    if let err { print("❌ whisper listen:", err); return }
                    guard let snap = snap else { return }
                    self.handleSnapshot(snap)
                }
        }

        func stopListening() {
            dbListener?.remove()
            dbListener = nil
        }

        private func handleSnapshot(_ snap: QuerySnapshot) {
            let fetchCap: CLLocationDistance = 5000
            let uLoc = parent.locationManager.lastLocation

            for change in snap.documentChanges {
                let id = change.document.documentID
                let w = WhisperRenderable(id: id, dict: change.document.data())

                if let loc = uLoc {
                    let d = loc.distance(from: CLLocation(latitude: w.latitude, longitude: w.longitude))
                    if d.isFinite == false || d > fetchCap { continue }
                }

                let unlocked = isUnlocked(w, user: uLoc)

                switch change.type {
                case .added, .modified:
                    whispers[id] = w
                    fetchMetaIfNeeded(for: id)
                    if unlocked { placeOrUpdateWhisper(w) } else { removeWhisperAnchor(id: id) }
                    refreshSidebarRow(for: id)
                case .removed:
                    whispers.removeValue(forKey: id)
                    attachmentsByWhisper.removeValue(forKey: id)
                    removeWhisperAnchor(id: id)
                    refreshSidebarRow(for: id)
                }
            }
        }

        // MARK: - Anchor placement

        private func placeOrUpdateWhisper(_ w: WhisperRenderable) {
            guard let arView else { return }
            guard isUnlocked(w, user: parent.locationManager.lastLocation) else {
                removeWhisperAnchor(id: w.id)
                return
            }

            if let existing = anchorMap[w.id] {
                updateVisual(for: existing, whisper: w)
                return
            }

            if let uLoc = parent.locationManager.lastLocation {
                // Place relative to user bearing/distance
                let localT = transformFor(whisper: w, from: uLoc)
                let proxy = AnchorEntity(world: localT)
                arView.scene.addAnchor(proxy)
                anchorMap[w.id] = proxy
                makeVisual(for: proxy, whisper: w)
                loadAttachments(for: w)
                fetchMetaIfNeeded(for: w.id)

                // Upgrade to real Geo anchor when localized & close enough
                if #available(iOS 14.0, *),
                   ARGeoTrackingConfiguration.isSupported,
                   isGeoLocalized,
                   uLoc.distance(from: CLLocation(latitude: w.latitude, longitude: w.longitude)) <= 60,
                   let geo = createARGeoAnchor(from: w) {

                    arView.session.add(anchor: geo)

                    let target = AnchoringComponent.Target.anchor(identifier: geo.identifier)
                    let geoEntity = AnchorEntity(target)

                    arView.scene.addAnchor(geoEntity)
                    for child in proxy.children { geoEntity.addChild(child) }
                    proxy.removeFromParent()
                    anchorMap[w.id] = geoEntity
                }
            } else {
                // No user location yet — just place it in front of camera so the user sees something
                let t = transformInFrontOfCamera(distance: 3)
                let proxy = AnchorEntity(world: t)
                arView.scene.addAnchor(proxy)
                anchorMap[w.id] = proxy
                makeVisual(for: proxy, whisper: w)
                loadAttachments(for: w)
                fetchMetaIfNeeded(for: w.id)
            }
        }

        private func removeWhisperAnchor(id: String) {
            if let anchor = anchorMap[id] {
                anchor.removeFromParent()
                anchorMap.removeValue(forKey: id)
            }
            players[id]?.pause()
            players.removeValue(forKey: id)
        }

        // MARK: - Visuals

        private func makeVisual(for anchor: AnchorEntity, whisper: WhisperRenderable) {
            let parentEntity = Entity()
            parentEntity.components.set(BillboardComponent())
            parentEntity.position.y = fSafe(cardHeight, min: 0.2, max: 5.0)

            if let cam = arView?.cameraTransform {
                var dist = simd_length(anchor.position(relativeTo: nil) - cam.translation)
                if dist.isFinite == false { dist = 5 }
                parentEntity.scale = .init(repeating: fSafe(dist / 8.0, min: 0.6, max: 2.0))
            }

            let sz = SIMD2<Float>(fSafe(cardSize.x, min: 0.1, max: 2.0),
                                  fSafe(cardSize.y, min: 0.1, max: 2.0))
            let baseColor = UIColor(red: 0.0, green: 0.9, blue: 1.0, alpha: 0.95)
            let front = ModelEntity(mesh: .generatePlane(width: sz.x, height: sz.y),
                                    materials: [UnlitMaterial(color: baseColor)])
            front.name = "tile_front:\(whisper.id)"

            let back = ModelEntity(mesh: .generatePlane(width: sz.x, height: sz.y),
                                   materials: [UnlitMaterial(color: baseColor)])
            back.transform.rotation = simd_quatf(angle: .pi, axis: [0, 1, 0])
            back.name = "tile_back:\(whisper.id)"

            let labelMesh = MeshResource.generateText(
                displayTitle(for: whisper.id, w: whisper),
                extrusionDepth: 0.004,
                font: .systemFont(ofSize: 0.16, weight: .semibold),
                containerFrame: .zero,
                alignment: .center,
                lineBreakMode: .byTruncatingTail
            )
            let label = ModelEntity(mesh: labelMesh, materials: [UnlitMaterial(color: .white)])
            label.position = pSafe([0, 0.32, 0])
            label.name = "label:\(whisper.id)"

            let unlocked = isUnlocked(whisper, user: parent.locationManager.lastLocation)
            let statusMesh = MeshResource.generateText(
                unlocked ? "UNLOCKED" : "LOCKED",
                extrusionDepth: 0.003,
                font: .systemFont(ofSize: 0.12, weight: .medium),
                containerFrame: .zero,
                alignment: .center,
                lineBreakMode: .byTruncatingTail
            )
            let statusMat = UnlitMaterial(color: unlocked ? .systemGreen : .systemRed)
            let status = ModelEntity(mesh: statusMesh, materials: [statusMat])
            status.position = pSafe([0, 0.12, 0])
            status.name = "status:\(whisper.id)"

            let parent = parentEntity
            parent.addChild(front)
            parent.addChild(back)
            parent.addChild(label)
            parent.addChild(status)

            anchor.addChild(parent)
            updateVisual(for: anchor, whisper: whisper)
        }

        private func updateLabelTitle(for anchor: AnchorEntity, whisper: WhisperRenderable) {
            if let label = anchor.findEntity(named: "label:\(whisper.id)") as? ModelEntity {
                let mesh = MeshResource.generateText(
                    displayTitle(for: whisper.id, w: whisper),
                    extrusionDepth: 0.004,
                    font: .systemFont(ofSize: 0.16, weight: .semibold),
                    containerFrame: .zero,
                    alignment: .center,
                    lineBreakMode: .byTruncatingTail
                )
                label.model = ModelComponent(mesh: mesh, materials: [UnlitMaterial(color: .white)])
            }
        }

        private func updateVisual(for anchor: AnchorEntity, whisper: WhisperRenderable) {
            let unlocked = isUnlocked(whisper, user: parent.locationManager.lastLocation)
            let tileColor = unlocked
                ? UIColor.systemGreen.withAlphaComponent(0.9)
                : UIColor.systemRed.withAlphaComponent(0.9)

            if let front = anchor.findEntity(named: "tile_front:\(whisper.id)") as? ModelEntity {
                front.model?.materials = [UnlitMaterial(color: tileColor)]
            }
            if let back = anchor.findEntity(named: "tile_back:\(whisper.id)") as? ModelEntity {
                back.model?.materials = [UnlitMaterial(color: tileColor)]
            }

            if let status = anchor.findEntity(named: "status:\(whisper.id)") as? ModelEntity {
                let mesh = MeshResource.generateText(
                    unlocked ? "UNLOCKED" : "LOCKED",
                    extrusionDepth: 0.003,
                    font: .systemFont(ofSize: 0.12, weight: .medium),
                    containerFrame: .zero,
                    alignment: .center,
                    lineBreakMode: .byTruncatingTail
                )
                status.model = ModelComponent(mesh: mesh, materials: [UnlitMaterial(color: unlocked ? .systemGreen : .systemRed)])
            }

            updateLabelTitle(for: anchor, whisper: whisper)
        }

        private func texture(from uiImage: UIImage) async throws -> TextureResource {
            if let cg = uiImage.cgImage {
                return try await TextureResource(
                    image: cg,
                    options: .init(semantic: .color)
                )
            }
            let ciContext = CIContext(options: nil)
            guard let ci = CIImage(image: uiImage),
                  let cg = ciContext.createCGImage(ci, from: ci.extent) else {
                throw NSError(domain: "ARWhisperView", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImage"])
            }
            return try await TextureResource(image: cg, options: .init(semantic: .color))
        }

        // MARK: - Attachments

        private func loadAttachments(for w: WhisperRenderable) {
            guard !loadedAttachmentFor.contains(w.id) else { return }
            loadedAttachmentFor.insert(w.id)

            Firestore.firestore()
                .collection("whispers").document(w.id)
                .collection("attachments")
                .order(by: "createdAt", descending: false)
                .limit(to: 5)
                .getDocuments { [weak self] snap, err in
                    guard let self else { return }
                    if let err { print("❌ [\(w.id)] attachments:", err); return }
                    let atts: [Attachment] = (snap?.documents ?? []).compactMap { try? $0.data(as: Attachment.self) }
                    self.attachmentsByWhisper[w.id] = atts
                    if self.isUnlocked(w, user: self.parent.locationManager.lastLocation) {
                        self.addAttachments(atts, for: w)
                    }
                    self.refreshSidebarRow(for: w.id)
                }
        }

        private func addAttachments(_ atts: [Attachment], for w: WhisperRenderable) {
            guard let anchor = self.anchorMap[w.id] else { return }

            var x: Float = -0.35
            let y: Float = 0.0

            for att in atts.prefix(5) {
                switch att.kind {
                case .image:
                    self.addImage(att, to: anchor, at: pSafe([x, y, 0]), wid: w.id)
                case .video:
                    self.addVideo(att, to: anchor, at: pSafe([x, y, 0]), wid: w.id)
                }
                x += fSafe(attachmentStep, min: 0.1, max: 1.0)
            }
        }

        private func addImage(_ att: Attachment, to anchor: AnchorEntity, at pos: SIMD3<Float>, wid: String) {
            let mesh = MeshResource.generatePlane(width: fSafe(imageSize, min: 0.1, max: 1.5),
                                                  height: fSafe(imageSize, min: 0.1, max: 1.5))
            let entity = ModelEntity(mesh: mesh)
            entity.name = "img:\(wid):\(att.id ?? UUID().uuidString)"
            entity.position = pSafe(pos)
            entity.components.set(BillboardComponent())
            anchor.addChild(entity)

            Task {
                do {
                    guard att.url.scheme?.lowercased() == "https" else { return }
                    let (data, _) = try await URLSession.shared.data(from: att.url)
                    guard let ui = UIImage(data: data) else { return }
                    let tex = try await texture(from: ui)
                    await MainActor.run {
                        var m = UnlitMaterial()
                        m.color = .init(texture: .init(tex))
                        entity.model?.materials = [m]
                    }
                } catch {
                    print("❌ [\(wid)] image load:", error.localizedDescription)
                }
            }
        }

        private func addVideo(_ att: Attachment, to anchor: AnchorEntity, at pos: SIMD3<Float>, wid: String) {
            let h = fSafe(videoHeight, min: 0.2, max: 1.0)
            let width: Float = h * 16.0 / 9.0
            let mesh = MeshResource.generatePlane(width: width, height: h)

            let entity = ModelEntity(mesh: mesh)
            entity.name = "video:\(wid):\(att.id ?? UUID().uuidString)"
            entity.position = pSafe(pos)
            entity.components.set(BillboardComponent())
            anchor.addChild(entity)

            if let posterURL = att.thumbUrl, posterURL.scheme?.lowercased() == "https" {
                Task {
                    if let (data, _) = try? await URLSession.shared.data(from: posterURL),
                       let ui = UIImage(data: data),
                       let tex = try? await texture(from: ui) {
                        await MainActor.run {
                            var poster = UnlitMaterial()
                            poster.color = .init(texture: .init(tex))
                            entity.model?.materials = [poster]
                        }
                    }
                }
            }

            let player = AVPlayer(url: att.url)
            players[wid] = player
            let videoMat = VideoMaterial(avPlayer: player)
            entity.model?.materials = [videoMat]

            let playMesh = MeshResource.generateText(
                "▶︎",
                extrusionDepth: 0.001,
                font: .systemFont(ofSize: 0.10, weight: .semibold),
                containerFrame: .zero,
                alignment: .center,
                lineBreakMode: .byTruncatingTail
            )
            let playLabel = ModelEntity(mesh: playMesh, materials: [UnlitMaterial(color: .white)])
            playLabel.position = pSafe([0, -(h / 2 + 0.05), 0])
            entity.addChild(playLabel)
        }

        // MARK: - Claim then open media

        private func claimThenOpen(wid: String, w: WhisperRenderable, arView: ARView, password: String?) {
            guard let loc = parent.locationManager.lastLocation else {
                self.toast("Location not available.")
                return
            }
            Task { @MainActor in
                do {
                    let (cents, msg) = try await ClaimService.claim(
                        whisperId: wid,
                        location: loc,
                        passwordPlain: password
                    )
                    self.toast(msg)
                    if cents > 0 { FoundAndNotifyStore.markFound(wid) }
                    self.openUnlockedMediaUI(wid: wid, w: w, arView: arView)
                } catch {
                    self.toast(error.localizedDescription)
                }
            }
        }

        // MARK: - Sidebar actions

        private func openWhisperMedia(_ wid: String) {
            guard let arView, let w = whispers[wid] else { return }

            guard isUnlocked(w, user: parent.locationManager.lastLocation) else {
                lockedAlert(for: w); return
            }

            promptPasswordIfNeeded(for: w) { [weak self] ok, pwd in
                guard let self, ok else { return }
                self.claimThenOpen(wid: wid, w: w, arView: arView, password: pwd)
            }
        }

        private func openUnlockedMediaUI(wid: String, w: WhisperRenderable, arView: ARView) {
            let anchor: AnchorEntity
            if let existing = anchorMap[wid] {
                anchor = existing
            } else {
                let t = transformInFrontOfCamera(distance: 2.0)
                let a = AnchorEntity(world: t)
                arView.scene.addAnchor(a)
                anchorMap[wid] = a
                makeVisual(for: a, whisper: w)
                if attachmentsByWhisper[wid] == nil { loadAttachments(for: w) }
                anchor = a
            }

            if let front = anchor.findEntity(named: "tile_front:\(wid)") as? ModelEntity {
                front.scale = [1.1, 1.1, 1.0]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { front.scale = [1.0, 1.0, 1.0] }
            }

            if let atts = attachmentsByWhisper[wid], !atts.isEmpty {
                if let v = atts.first(where: { $0.kind == .video }) {
                    presentVideoFullscreen(url: v.url)
                } else if let img = atts.first(where: { $0.kind == .image }) {
                    presentImageFullscreen(img)
                } else {
                    let a = UIAlertController(title: "No Media",
                                              message: "This whisper has no playable photos or videos.",
                                              preferredStyle: .alert)
                    a.addAction(UIAlertAction(title: "OK", style: .default))
                    arView.window?.rootViewController?.present(a, animated: true)
                }
            } else {
                loadAttachments(for: w)
            }
        }

        private func lockedAlert(for w: WhisperRenderable) {
            guard let arView else { return }
            let user = parent.locationManager.lastLocation
            let reason: String = {
                if Date() < w.unlockAt { return "⏳ Unlocks at \(w.unlockAt.formatted())" }
                guard let user else { return "📍 Move closer" }
                let drop = CLLocation(latitude: w.latitude, longitude: w.longitude)
                let dist = user.distance(from: drop)
                guard dist.isFinite else { return "📍 Move closer" }
                let left = max(0, Int(w.radiusMeters - dist))
                return "📍 Move closer (~\(left)m)"
            }()
            let a = UIAlertController(title: "Locked", message: reason, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            arView.window?.rootViewController?.present(a, animated: true)
        }

        private func canDelete(_ w: WhisperRenderable) -> Bool {
            let uid = Auth.auth().currentUser?.uid
            if let owner = w.ownerId, let uid, owner == uid { return true }
            if let owner = w.ownerId,
               owner.hasPrefix("device-"),
               let dev = UIDevice.current.identifierForVendor?.uuidString,
               owner == "device-\(dev)" { return true }
            return false
        }

        private func confirmDelete(_ w: WhisperRenderable) {
            guard let arView else { return }
            let alert = UIAlertController(
                title: "Delete Whisper?",
                message: "This will mark it for deletion (free – 24h purge).",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive, handler: { [weak self] _ in
                Task { await self?.softDeleteWhisper(w) }
            }))
            arView.window?.rootViewController?.present(alert, animated: true)
        }

        private func toast(_ text: String) {
            guard let arView else { return }
            let label = UILabel()
            label.text = text
            label.textColor = .white
            label.font = .systemFont(ofSize: 14, weight: .semibold)
            label.numberOfLines = 0
            label.textAlignment = .center
            label.backgroundColor = UIColor.black.withAlphaComponent(0.75)
            label.layer.cornerRadius = 12
            label.layer.masksToBounds = true
            label.translatesAutoresizingMaskIntoConstraints = false

            arView.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: arView.centerXAnchor),
                label.bottomAnchor.constraint(equalTo: arView.safeAreaLayoutGuide.bottomAnchor, constant: -20),
                label.widthAnchor.constraint(lessThanOrEqualTo: arView.widthAnchor, multiplier: 0.9)
            ])
            label.alpha = 0
            UIView.animate(withDuration: 0.2, animations: { label.alpha = 1 }) { _ in
                UIView.animate(withDuration: 0.2, delay: 1.2, options: [], animations: { label.alpha = 0 }) { _ in
                    label.removeFromSuperview()
                }
            }
        }

        private func removeLocalState(for wid: String) {
            removeWhisperAnchor(id: wid)
            whispers.removeValue(forKey: wid)
            attachmentsByWhisper.removeValue(forKey: wid)
        }

        private func softDeleteWhisper(_ w: WhisperRenderable) async {
            let db = Firestore.firestore()
            let docRef = db.collection("whispers").document(w.id)
            let now = Date()
            let purgeAt = now.addingTimeInterval(24 * 60 * 60)

            do {
                try await docRef.updateData([
                    "deleted": true,
                    "deletedAt": Timestamp(date: now),
                    "purgeAt": Timestamp(date: purgeAt),
                    "deleteTier": "free-queued"
                ])
                await MainActor.run {
                    self.toast("Deleted")
                    self.removeLocalState(for: w.id)
                    self.refreshSidebarRow(for: w.id)
                }
            } catch {
                await MainActor.run { self.toast("Delete failed") }
                print("❌ softDelete failed:", error.localizedDescription)
            }
        }

        // MARK: - Fullscreen media

        private func presentVideoFullscreen(url: URL) {
            guard let arView else { return }

            guard url.scheme?.lowercased() == "https" else {
                let a = UIAlertController(title: "Cannot Play",
                                          message: "The video URL must be HTTPS.",
                                          preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "OK", style: .default))
                arView.window?.rootViewController?.present(a, animated: true)
                return
            }

            let asset = AVURLAsset(url: url)
            Task { @MainActor in
                do {
                    let playable = try await asset.load(.isPlayable)
                    guard playable else {
                        let a = UIAlertController(title: "Cannot Play",
                                                  message: "This file isn’t playable on iOS.",
                                                  preferredStyle: .alert)
                        a.addAction(UIAlertAction(title: "OK", style: .default))
                        arView.window?.rootViewController?.present(a, animated: true)
                        return
                    }

                    let item = AVPlayerItem(asset: asset)
                    let player = AVPlayer(playerItem: item)
                    player.allowsExternalPlayback = false
                    player.automaticallyWaitsToMinimizeStalling = true

                    do {
                        let s = AVAudioSession.sharedInstance()
                        try s.setCategory(.playback, mode: .moviePlayback, options: [.duckOthers])
                        try s.setActive(true)
                    } catch {
                        print("⚠️ Audio session:", error.localizedDescription)
                    }

                    let vc = AVPlayerViewController()
                    vc.player = player
                    vc.modalPresentationStyle = .fullScreen
                    if #available(iOS 14.0, *) {
                        vc.allowsPictureInPicturePlayback = true
                    }
                    vc.exitsFullScreenWhenPlaybackEnds = true

                    arView.window?.rootViewController?.present(vc, animated: true) {
                        player.play()
                    }
                } catch {
                    let a = UIAlertController(title: "Cannot Play",
                                              message: error.localizedDescription,
                                              preferredStyle: .alert)
                    a.addAction(UIAlertAction(title: "OK", style: .default))
                    arView.window?.rootViewController?.present(a, animated: true)
                }
            }
        }

        private func presentImageFullscreen(_ att: Attachment) {
            guard let arView else { return }
            let overlay = UIImageView(frame: arView.bounds)
            overlay.backgroundColor = UIColor.black.withAlphaComponent(0.9)
            overlay.contentMode = .scaleAspectFit
            overlay.isUserInteractionEnabled = true
            overlay.alpha = 0
            overlay.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismissFullImage(_:))))
            arView.addSubview(overlay)

            Task {
                if let (data, _) = try? await URLSession.shared.data(from: att.url),
                   let img = UIImage(data: data) {
                    await MainActor.run {
                        overlay.image = img
                        UIView.animate(withDuration: 0.2) { overlay.alpha = 1 }
                    }
                } else {
                    await MainActor.run { overlay.removeFromSuperview() }
                }
            }
        }

        @objc private func dismissFullImage(_ g: UITapGestureRecognizer) {
            if let v = g.view {
                UIView.animate(withDuration: 0.2, animations: { v.alpha = 0 }) { _ in v.removeFromSuperview() }
            }
        }

        // MARK: - Tap (AR view)

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let arView else { return }
            let p = g.location(in: arView)

            guard let entity = arView.entity(at: p) else { return }
            let entityName = entity.name

            // Tapped a video plane?
            if entityName.hasPrefix("video:") {
                let parts = entityName.split(separator: ":").map(String.init)
                let wid   = parts.count >= 2 ? parts[1] : ""
                // let attId: String? = parts.count >= 3 ? parts[2] : nil

                guard let w = whispers[wid] else { return }

                guard isUnlocked(w, user: parent.locationManager.lastLocation) else {
                    lockedAlert(for: w)
                    return
                }

                promptPasswordIfNeeded(for: w) { [weak self] ok, pwd in
                    guard let self, ok else { return }
                    self.claimThenOpen(wid: wid, w: w, arView: arView, password: pwd)
                }
                return
            }

            // Otherwise: show info for the tapped whisper (via its anchor)
            if let anchor = entity.anchor,
               let (id, _) = anchorMap.first(where: { $0.value == anchor }) {
                presentInfo(for: id)
            }
        }

        private func presentInfo(for id: String) {
            guard let w = whispers[id], let arView else { return }
            let title = (namesById[id]?.isEmpty == false) ? namesById[id]! : "Whisper"
            let msg = """
            \(title)
            Location: \(String(format: "%.5f, %.5f", w.latitude, w.longitude))
            Radius: \(Int(w.radiusMeters))m
            Unlocks: \(w.unlockAt.formatted())
            Balance: \(currency(centsById[id], fallback: w.balance))
            """
            let alert = UIAlertController(title: "Whisper", message: msg, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            arView.window?.rootViewController?.present(alert, animated: true)
        }

        // MARK: - Helpers

        private func transformFor(whisper: WhisperRenderable, from user: CLLocation) -> simd_float4x4 {
            let dest = CLLocation(latitude: whisper.latitude, longitude: whisper.longitude)
            var d = Float(user.distance(from: dest))
            if d.isFinite == false { d = 5 }
            let bearing = Float(bearingBetween(
                startLat: user.coordinate.latitude,
                startLon: user.coordinate.longitude,
                endLat: whisper.latitude,
                endLon: whisper.longitude
            ))
            let r = fSafe(d, min: 2.5, max: 60)
            let x = r * sin(bearing)
            let z = -r * cos(bearing)
            var t = matrix_identity_float4x4
            t.columns.3 = SIMD4<Float>(x, 0, z, 1)
            return t
        }

        private func transformInFrontOfCamera(distance: Float) -> simd_float4x4 {
            let dist = fSafe(distance, min: 0.2, max: 8.0)
            guard let arView, let cam = arView.session.currentFrame?.camera else {
                var t = matrix_identity_float4x4
                t.columns.3 = SIMD4<Float>(0, 0, -dist, 1)
                return t
            }
            var t = cam.transform
            let fwd = SIMD3<Float>(-t.columns.2.x, -t.columns.2.y, -t.columns.2.z)
            t.columns.3.x += fwd.x * dist
            t.columns.3.y += fwd.y * dist
            t.columns.3.z += fwd.z * dist
            return t
        }

        @available(iOS 14.0, *)
        private func createARGeoAnchor(from w: WhisperRenderable) -> ARGeoAnchor? {
            ARGeoAnchor(coordinate: CLLocationCoordinate2D(latitude: w.latitude, longitude: w.longitude))
        }

        private func bearingBetween(startLat: Double, startLon: Double, endLat: Double, endLon: Double) -> Double {
            let φ1 = startLat * .pi / 180
            let φ2 = endLat * .pi / 180
            let Δλ = (endLon - startLon) * .pi / 180
            let y = sin(Δλ) * cos(φ2)
            let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
            var θ = atan2(y, x)
            if θ < 0 { θ += 2 * .pi }
            return θ
        }

        // MARK: - Currency helpers

        private func currency(_ cents: Int?, fallback dollars: Double?) -> String {
            if let c = cents, c >= 0 {
                let d = Double(c) / 100.0
                return String(format: "$%.2f", d)
            }
            if let d = dollars, d.isFinite {
                return String(format: "$%.2f", d)
            }
            return "$0.00"
        }

        // MARK: - ARSessionDelegate

        nonisolated func session(_ session: ARSession, didChange geoTrackingStatus: ARGeoTrackingStatus) {
            Task { @MainActor in
                self.isGeoLocalized = (geoTrackingStatus.state == .localized)
                // If we just localized, try upgrading placements
                self.reapplyPlacementNearUser()
            }
        }
        nonisolated func session(_ session: ARSession, didFailWithError error: Error) { print("AR failed:", error.localizedDescription) }
        nonisolated func sessionWasInterrupted(_ session: ARSession) { print("AR interrupted") }
        nonisolated func sessionInterruptionEnded(_ session: ARSession) { print("AR resumed") }
    }
}

// MARK: - Sidebar UI (UIKit)

private struct SidebarItem: Hashable {
    let id: String
    let title: String
    var subtitle: String
    var canDelete: Bool
}

private final class SidebarView: UIView {
    var trailingConstraint: NSLayoutConstraint?
    var isShown: Bool = false

    var onOpen: ((String) -> Void)?
    var onInfo: ((String) -> Void)?
    var onDelete: ((String) -> Void)?

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let stack = UIStackView()
    private var rows: [String: SidebarRow] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.masksToBounds = true

        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let title = UILabel()
        title.text = "Media Nearby"
        title.font = .boldSystemFont(ofSize: 17)
        title.textColor = .white
        title.translatesAutoresizingMaskIntoConstraints = false

        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroller = UIScrollView()
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(stack)

        blur.contentView.addSubview(title)
        blur.contentView.addSubview(scroller)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -14),
            title.topAnchor.constraint(equalTo: blur.contentView.safeAreaLayoutGuide.topAnchor, constant: 10),

            scroller.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
            scroller.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroller.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scroller.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: scroller.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: scroller.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: scroller.bottomAnchor, constant: -12),
            stack.widthAnchor.constraint(equalTo: scroller.widthAnchor, constant: -20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(items: [SidebarItem]) {
        let existing = Set(rows.keys)
        let next = Set(items.map { $0.id })
        for id in existing.subtracting(next) {
            rows[id]?.removeFromSuperview()
            rows.removeValue(forKey: id)
        }
        for item in items {
            if let row = rows[item.id] {
                row.configure(title: item.title, subtitle: item.subtitle, canDelete: item.canDelete)
            } else {
                let row = SidebarRow()
                row.configure(title: item.title, subtitle: item.subtitle, canDelete: item.canDelete)
                row.onOpen = { [weak self] in self?.onOpen?(item.id) }
                row.onInfo = { [weak self] in self?.onInfo?(item.id) }
                row.onDelete = { [weak self] in self?.onDelete?(item.id) }
                rows[item.id] = row
                stack.addArrangedSubview(row)
            }
        }
    }

    func updateItem(id: String, subtitle: String, canDelete: Bool) {
        rows[id]?.configure(title: rows[id]?.titleText ?? "Whisper", subtitle: subtitle, canDelete: canDelete)
    }
}

private final class SidebarRow: UIView {
    var onOpen: (() -> Void)?
    var onInfo: (() -> Void)?
    var onDelete: (() -> Void)?

    private let title = UILabel()
    private let subtitle = UILabel()
    private let openBtn = UIButton(type: .system)
    private let infoBtn = UIButton(type: .system)
    private let delBtn = UIButton(type: .system)

    var titleText: String { title.text ?? "" }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        backgroundColor = UIColor.white.withAlphaComponent(0.08)

        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .white
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = UIColor.white.withAlphaComponent(0.9)
        subtitle.numberOfLines = 1

        styleActionButton(openBtn, title: "Open")
        styleActionButton(infoBtn, title: "Info")
        styleActionButton(delBtn, title: "Delete")

        openBtn.addTarget(self, action: #selector(tOpen), for: .touchUpInside)
        infoBtn.addTarget(self, action: #selector(tInfo), for: .touchUpInside)
        delBtn.addTarget(self, action: #selector(tDelete), for: .touchUpInside)

        let vstack = UIStackView(arrangedSubviews: [title, subtitle])
        vstack.axis = .vertical
        vstack.spacing = 2
        vstack.translatesAutoresizingMaskIntoConstraints = false

        let hstack = UIStackView(arrangedSubviews: [openBtn, infoBtn, delBtn])
        hstack.axis = .horizontal
        hstack.spacing = 8
        hstack.distribution = .fillProportionally
        hstack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(vstack)
        addSubview(hstack)

        NSLayoutConstraint.activate([
            vstack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            vstack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            vstack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            hstack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            hstack.topAnchor.constraint(equalTo: vstack.bottomAnchor, constant: 8),
            hstack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, subtitle: String, canDelete: Bool) {
        self.title.text = title
        self.subtitle.text = subtitle
        delBtn.isHidden = !canDelete
    }

    @objc private func tOpen() { onOpen?() }
    @objc private func tInfo() { onInfo?() }
    @objc private func tDelete() { onDelete?() }
}

// Shared modern button styling
private func styleActionButton(_ button: UIButton, title: String) {
    button.translatesAutoresizingMaskIntoConstraints = false
    if #available(iOS 15.0, *) {
        var conf = UIButton.Configuration.plain()
        conf.title = title
        conf.baseForegroundColor = .white
        conf.background.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        conf.background.cornerRadius = 8
        conf.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        button.configuration = conf
    } else {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        button.layer.cornerRadius = 8
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
    }
}
