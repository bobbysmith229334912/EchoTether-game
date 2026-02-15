//
//  ARWhisperCoordinator.swift
//  EchoTether
//
//  FULL REWRITE (copy-paste)
//  ✅ Character model per whisper (selectable in AR via button menu)
//  ✅ Menu is SAFE (filters blanks/whitespace so no load crashes)
//  ✅ Plane snap (horizontal) so it sits on real surfaces (more realistic)
//  ✅ Fix: no RealityKit.Cancellable — uses AnyCancellable safely
//  ✅ Prevent “on top of me” (min distance clamp) + stable spread
//  ✅ Keeps placement + size EXACTLY as your last good version (cardSize/cardHeight + transforms unchanged)
//
//  NOTE: This file references your existing types (do NOT redefine them here):
//   - LocationManager (ObservableObject with @Published lastLocation, start(), stop())
//   - WhisperRenderable (id, latitude, longitude, radiusMeters, unlockAt, balance, ownerId, passwordHash, init(id:dict:))
//   - Attachment, SidebarView, SidebarItem, ClaimService, FoundAndNotifyStore
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
import CryptoKit

@MainActor
final class ARWhisperCoordinator: NSObject, ARSessionDelegate, ObservableObject {

    // MARK: - Parent + AR
    let parent: ARWhisperView
    weak var arView: ARView?

    // MARK: - Location
    private var locCancellable: AnyCancellable?
    private var lastPlacedFix: CLLocation?

    // MARK: - UI
    weak var sidebarButton: UIButton?
    weak var modelButton: UIButton?
    private var scrimView: UIView?
    private var sidebarView: SidebarView?

    // MARK: - Data & state
    private var dbListener: ListenerRegistration?
    private var whispers: [String: WhisperRenderable] = [:]
    private var anchorMap: [String: AnchorEntity] = [:]
    private var geoAnchoredIds: Set<String> = []

    private var attachmentsByWhisper: [String: [Attachment]] = [:]
    private var loadedAttachmentFor: Set<String> = []
    private var isGeoLocalized = false

    // MARK: - Meta caches
    private var namesById: [String: String] = [:]
    private var centsById: [String: Int] = [:]
    private var fetchInFlight: Set<String> = []

    // MARK: - Media players
    private var players: [String: AVPlayer] = [:]

    // MARK: - Layout (DO NOT CHANGE — this is your “last good” sizing)
    private let cardSize: SIMD2<Float> = [0.45, 0.45]
    private let cardHeight: Float      = 1.25

    // MARK: - Placement tuning (fix “on top of me”)
    private let minARDistance: Float = 10.0     // never closer than this
    private let maxARDistance: Float = 55.0     // don’t go crazy far
    private let rebuildMoveMeters: CLLocationDistance = 18.0
    private let rebuildMinInterval: TimeInterval = 1.25
    private var lastRebuildAt: Date = .distantPast

    // MARK: - Character selection
    // ✅ ARWhisperView sets this list. Keep defaults safe.
    var availableCharacterModels: [String] = ["Sentinel", "MiaDance"]
    @AppStorage("arSelectedCharacterModel") private var selectedCharacterModel: String = "Sentinel"

    // MARK: - Character (model)
    private var characterTemplateCache: [String: Entity] = [:]
    private let characterTargetHeightMeters: Float = 1.25
    private let characterOffset: SIMD3<Float> = [0.0, 0.0, -0.85]
    private var characterIdleSubs: [String: AnyCancellable] = [:]

    init(parent: ARWhisperView) {
        self.parent = parent
        super.init()
    }

    deinit {
        dbListener?.remove()
        players.values.forEach { $0.pause() }
        characterIdleSubs.values.forEach { $0.cancel() }
        locCancellable?.cancel()
    }

    // MARK: - SAFE model list (prevents blank names / whitespace)
    private func sanitizedModels(_ models: [String]) -> [String] {
        let cleaned = models
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Guarantee at least one valid choice so menu + loader never break
        if cleaned.isEmpty { return ["Sentinel"] }
        return cleaned
    }

    private func resolvedSelectedModel() -> String {
        let safe = sanitizedModels(availableCharacterModels)
        if safe.contains(selectedCharacterModel) { return selectedCharacterModel }
        // If selection got invalid (file removed/renamed), fall back cleanly
        selectedCharacterModel = safe.first ?? "Sentinel"
        return selectedCharacterModel
    }

    // MARK: - Model menu
    @available(iOS 14.0, *)
    func makeModelMenu() -> UIMenu {
        let safeModels = sanitizedModels(availableCharacterModels)

        // Ensure current selection is valid
        if safeModels.contains(selectedCharacterModel) == false {
            selectedCharacterModel = safeModels.first ?? "Sentinel"
        }

        let actions = safeModels.map { modelName in
            UIAction(
                title: modelName,
                state: (modelName == selectedCharacterModel) ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                self.selectedCharacterModel = modelName
                self.toast("Character: \(modelName)")
                self.refreshAllCharacters()
                if #available(iOS 14.0, *) {
                    self.modelButton?.menu = self.makeModelMenu() // refresh checkmarks
                }
            }
        }

        return UIMenu(title: "Choose Character", children: actions)
    }

    private func refreshAllCharacters() {
        for (wid, anchor) in anchorMap {
            // remove old character
            if let existing = anchor.findEntity(named: "character:\(wid)") {
                existing.removeFromParent()
            }
            // reattach with new choice
            if let root = anchor.children.first(where: { $0.name == "root:\(wid)" }) {
                attachCharacter(to: root, whisperId: wid)
            }
        }
    }

    // MARK: - Location binding
    func bindLocation() {
        unbindLocation()

        locCancellable = parent.locationManager.$lastLocation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loc in
                guard let self, let loc else { return }

                let now = Date()
                if now.timeIntervalSince(self.lastRebuildAt) < self.rebuildMinInterval { return }

                let shouldRebuild: Bool = {
                    guard let prev = self.lastPlacedFix else { return true }
                    let moved = prev.distance(from: loc)
                    return moved >= self.rebuildMoveMeters ||
                           loc.timestamp > prev.timestamp ||
                           (loc.horizontalAccuracy > 0 && loc.horizontalAccuracy < prev.horizontalAccuracy)
                }()

                if shouldRebuild {
                    self.lastRebuildAt = now
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
        for (_, w) in whispers {
            if isUnlocked(w, user: parent.locationManager.lastLocation) {
                placeOrUpdateWhisper(w, allowMove: true)
            } else {
                removeWhisperAnchor(id: w.id)
            }
        }
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
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(false, nil) })
        alert.addAction(UIAlertAction(title: "Unlock", style: .default) { [weak self] _ in
            let input = alert.textFields?.first?.text ?? ""
            let ok = self?.sha256Hex(input).caseInsensitiveCompare(stored) == .orderedSame
            if ok == true { completion(true, input) }
            else {
                self?.toast("Incorrect password")
                completion(false, nil)
            }
        })
        arView.window?.rootViewController?.present(alert, animated: true)
    }

    // MARK: - Meta fetch (name + balanceCents)
    private func fetchMetaIfNeeded(for id: String) {
        guard (namesById[id] == nil || centsById[id] == nil),
              !fetchInFlight.contains(id) else { return }

        fetchInFlight.insert(id)

        Firestore.firestore()
            .collection("whispers").document(id)
            .getDocument { [weak self] snap, err in
                guard let self else { return }
                self.fetchInFlight.remove(id)
                guard err == nil, let data = snap?.data() else { return }

                if let name = data["name"] as? String, !name.isEmpty { self.namesById[id] = name }
                if let cents = (data["balanceCents"] as? NSNumber)?.intValue { self.centsById[id] = max(0, cents) }

                self.rebuildSidebarIfVisible()
                if let anchor = self.anchorMap[id], let w = self.whispers[id] {
                    self.updateLabelTitle(for: anchor, whisper: w)
                }
            }
    }

    private func currency(_ cents: Int?, fallback dollars: Double?) -> String {
        if let c = cents, c >= 0 { return String(format: "$%.2f", Double(c) / 100.0) }
        if let d = dollars, d.isFinite { return String(format: "$%.2f", d) }
        return "$0.00"
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

    @objc func toggleSidebar() {
        sidebarView?.isShown == true ? hideSidebar() : showSidebar()
    }

    private func showSidebar() {
        guard let panel = sidebarView, let scrim = scrimView, let arView else { return }

        let items = whispers.keys.compactMap { wid -> SidebarItem? in
            guard let w = whispers[wid] else { return nil }
            guard isUnlocked(w, user: parent.locationManager.lastLocation) else { return nil }

            fetchMetaIfNeeded(for: wid)
            let count = attachmentsByWhisper[wid]?.count ?? 0

            return SidebarItem(
                id: wid,
                title: displayTitle(for: wid, w: w),
                subtitle: count > 0 ? "\(count) item\(count == 1 ? "" : "s")" : "Loading…",
                canDelete: canDelete(w)
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

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

    // MARK: - Firestore
    func startListeningToWhispers() {
        let db = Firestore.firestore()
        dbListener = db.collection("whispers")
            .whereField("deleted", isEqualTo: false)
            .whereField("unlockAt", isLessThanOrEqualTo: Timestamp(date: Date()))
            .addSnapshotListener { [weak self] snap, err in
                guard let self else { return }
                if let err { print("❌ whisper listen:", err); return }
                guard let snap else { return }
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

                if unlocked { placeOrUpdateWhisper(w, allowMove: true) }
                else { removeWhisperAnchor(id: id) }

            case .removed:
                whispers.removeValue(forKey: id)
                attachmentsByWhisper.removeValue(forKey: id)
                removeWhisperAnchor(id: id)
            }
        }
    }

    // MARK: - Plane snap (horizontal surfaces)
    private func snappedYForHorizontalSurface(x: Float, z: Float, defaultY: Float = 0) -> Float {
        guard let arView else { return defaultY }
        guard #available(iOS 13.0, *) else { return defaultY }

        let origin = SIMD3<Float>(x, 5.0, z)
        let direction = SIMD3<Float>(0, -1, 0)

        let q1 = ARRaycastQuery(origin: origin, direction: direction, allowing: .existingPlaneGeometry, alignment: .horizontal)
        if let hit = arView.session.raycast(q1).first {
            return hit.worldTransform.columns.3.y
        }

        let q2 = ARRaycastQuery(origin: origin, direction: direction, allowing: .estimatedPlane, alignment: .horizontal)
        if let hit = arView.session.raycast(q2).first {
            return hit.worldTransform.columns.3.y
        }

        return defaultY
    }

    // MARK: - Stable spread offset (prevents overlap)
    private func stableSpreadOffset(for whisperId: String) -> SIMD3<Float> {
        let digest = SHA256.hash(data: Data(whisperId.utf8))
        let bytes = Array(digest)

        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(bytes[i]) }

        let bucket = Int(v % 18)
        let angle = Float(bucket) * (2.0 * .pi / 18.0)
        let radius: Float = 0.85

        let x = cos(angle) * radius
        let z = sin(angle) * radius
        return SIMD3<Float>(x, 0, z)
    }

    // MARK: - Character loading
    private func loadCharacterTemplateIfNeeded(modelName: String) async -> Entity? {
        if let cached = characterTemplateCache[modelName] { return cached }

        do {
            let e = try await Entity(named: modelName)
            e.position = SIMD3<Float>(0, 0, 0)
            e.orientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            e.scale = SIMD3<Float>(repeating: 1.0)
            characterTemplateCache[modelName] = e
            return e
        } catch {
            print("❌ Character load failed for \(modelName). Make sure \(modelName).usdz is in target membership.")
            print("   Error:", error.localizedDescription)
            return nil
        }
    }

    private func forEachEntityRecursively(_ root: Entity, _ body: (Entity) -> Void) {
        body(root)
        for child in root.children {
            forEachEntityRecursively(child, body)
        }
    }

    private func playAllAnimationsRecursively(on root: Entity) -> Int {
        var count = 0
        forEachEntityRecursively(root) { e in
            let anims = e.availableAnimations
            if anims.isEmpty == false {
                for a in anims {
                    e.playAnimation(a.repeat())
                    count += 1
                }
            }
        }
        return count
    }

    private func startCharacterIdle(for entity: Entity, whisperId: String, basePos: SIMD3<Float>) {
        characterIdleSubs[whisperId]?.cancel()
        guard let arView else { return }

        let start = CACurrentMediaTime()
        let sub = arView.scene.subscribe(to: SceneEvents.Update.self) { _ in
            let t = Float(CACurrentMediaTime() - start)
            let bob = 0.05 * sin(t * 2.0)
            let yaw = 0.22 * sin(t * 1.1)

            entity.position = SIMD3<Float>(basePos.x, basePos.y + bob, basePos.z)
            entity.orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        }

        characterIdleSubs[whisperId] = AnyCancellable { sub.cancel() }
    }

    private func normalizeHeightScale(for entity: Entity, targetMeters: Float) {
        let bounds = entity.visualBounds(relativeTo: nil)
        let height = bounds.extents.y
        guard height.isFinite, height > 0.001 else { return }
        let s = targetMeters / height
        entity.scale = SIMD3<Float>(repeating: s)
    }

    private func attachCharacter(to parent: Entity, whisperId: String) {
        Task {
            // ✅ SAFE selection (prevents blanks or removed names)
            let modelName = resolvedSelectedModel()
            guard let template = await loadCharacterTemplateIfNeeded(modelName: modelName) else { return }

            if let existing = parent.findEntity(named: "character:\(whisperId)") {
                existing.removeFromParent()
            }
            characterIdleSubs[whisperId]?.cancel()
            characterIdleSubs.removeValue(forKey: whisperId)

            let character = template.clone(recursive: true)
            character.name = "character:\(whisperId)"

            normalizeHeightScale(for: character, targetMeters: characterTargetHeightMeters)

            let basePos = characterOffset
            character.position = basePos
            character.orientation = simd_quatf(angle: 0.0, axis: SIMD3<Float>(0, 1, 0))

            await MainActor.run {
                parent.addChild(character)
            }

            let played = playAllAnimationsRecursively(on: character)
            if played == 0 {
                startCharacterIdle(for: character, whisperId: whisperId, basePos: basePos)
            } else {
                print("✅ Played \(played) animations for \(modelName)")
            }
        }
    }

    // MARK: - Anchor placement
    private func placeOrUpdateWhisper(_ w: WhisperRenderable, allowMove: Bool) {
        guard let arView else { return }
        guard isUnlocked(w, user: parent.locationManager.lastLocation) else {
            removeWhisperAnchor(id: w.id)
            return
        }

        if let existing = anchorMap[w.id] {
            if allowMove, geoAnchoredIds.contains(w.id) == false,
               let uLoc = parent.locationManager.lastLocation {
                let newT = transformFor(whisper: w, from: uLoc)
                existing.transform = Transform(matrix: newT)
            }
            updateVisual(for: existing, whisper: w)
            return
        }

        if let uLoc = parent.locationManager.lastLocation {
            let localT = transformFor(whisper: w, from: uLoc)
            let proxy = AnchorEntity(world: localT)
            arView.scene.addAnchor(proxy)
            anchorMap[w.id] = proxy

            makeVisual(for: proxy, whisper: w)
            fetchMetaIfNeeded(for: w.id)

        } else {
            let t = transformInFrontOfCamera(distance: 3.0, whisperId: w.id)
            let proxy = AnchorEntity(world: t)
            arView.scene.addAnchor(proxy)
            anchorMap[w.id] = proxy

            makeVisual(for: proxy, whisper: w)
            fetchMetaIfNeeded(for: w.id)
        }
    }

    private func removeWhisperAnchor(id: String) {
        if let anchor = anchorMap[id] {
            anchor.removeFromParent()
            anchorMap.removeValue(forKey: id)
        }
        geoAnchoredIds.remove(id)

        players[id]?.pause()
        players.removeValue(forKey: id)

        characterIdleSubs[id]?.cancel()
        characterIdleSubs.removeValue(forKey: id)
    }

    // MARK: - Visual
    private func makeVisual(for anchor: AnchorEntity, whisper: WhisperRenderable) {
        let root = Entity()
        root.name = "root:\(whisper.id)"
        root.position = SIMD3<Float>(0, cardHeight, 0)

        let billboard = Entity()
        billboard.components.set(BillboardComponent())

        let sz = cardSize
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
        label.position = SIMD3<Float>(0, 0.32, 0)
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
        status.position = SIMD3<Float>(0, 0.12, 0)
        status.name = "status:\(whisper.id)"

        billboard.addChild(front)
        billboard.addChild(back)
        billboard.addChild(label)
        billboard.addChild(status)

        root.addChild(billboard)

        // ✅ Attach selected character (NOT billboarded)
        attachCharacter(to: root, whisperId: whisper.id)

        anchor.addChild(root)
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
            status.model = ModelComponent(
                mesh: mesh,
                materials: [UnlitMaterial(color: unlocked ? .systemGreen : .systemRed)]
            )
        }

        updateLabelTitle(for: anchor, whisper: whisper)
    }

    // MARK: - Tap (hook)
    @objc func handleTap(_ g: UITapGestureRecognizer) {
        guard let arView else { return }
        let p = g.location(in: arView)
        guard let entity = arView.entity(at: p) else { return }

        if let anchor = entity.anchor,
           let (id, _) = anchorMap.first(where: { $0.value == anchor }) {
            presentInfo(for: id)
        }
    }

    // MARK: - Info
    private func presentInfo(for id: String) {
        guard let w = whispers[id], let arView else { return }

        let title = (namesById[id]?.isEmpty == false) ? namesById[id]! : "Whisper"
        let msg = """
        \(title)
        Location: \(String(format: "%.5f, %.5f", w.latitude, w.longitude))
        Radius: \(Int(w.radiusMeters))m
        Unlocks: \(w.unlockAt.formatted())
        Balance: \(currency(centsById[id], fallback: w.balance))
        Character: \(resolvedSelectedModel())
        """

        let alert = UIAlertController(title: "Whisper", message: msg, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        arView.window?.rootViewController?.present(alert, animated: true)
    }

    // MARK: - Claim/open hooks (keep stubs, wire to your existing code)
    private func openWhisperMedia(_ wid: String) {
        toast("Open \(wid)")
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
        toast("Delete not wired in this rewrite stub")
    }

    // MARK: - Toast
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

    // MARK: - Transforms (min distance + plane snap)  ✅ DO NOT CHANGE
    private func transformFor(whisper: WhisperRenderable, from user: CLLocation) -> simd_float4x4 {
        let dest = CLLocation(latitude: whisper.latitude, longitude: whisper.longitude)

        var d = Float(user.distance(from: dest))
        if d.isFinite == false { d = minARDistance }

        let r = max(minARDistance, min(d, maxARDistance))

        let bearing = Float(bearingBetween(
            startLat: user.coordinate.latitude,
            startLon: user.coordinate.longitude,
            endLat: whisper.latitude,
            endLon: whisper.longitude
        ))

        let baseX = r * sin(bearing)
        let baseZ = -r * cos(bearing)

        let spread = stableSpreadOffset(for: whisper.id)

        let y = snappedYForHorizontalSurface(x: baseX + spread.x, z: baseZ + spread.z, defaultY: 0)

        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(baseX + spread.x, y, baseZ + spread.z, 1)
        return t
    }

    private func transformInFrontOfCamera(distance: Float, whisperId: String) -> simd_float4x4 {
        let dist = max(0.5, min(distance, 8.0))
        let spread = stableSpreadOffset(for: whisperId) * 0.35

        guard let arView, let cam = arView.session.currentFrame?.camera else {
            var t = matrix_identity_float4x4
            t.columns.3 = SIMD4<Float>(spread.x, 0, -dist + spread.z, 1)
            return t
        }

        var t = cam.transform
        let fwd = SIMD3<Float>(-t.columns.2.x, -t.columns.2.y, -t.columns.2.z)
        t.columns.3.x += fwd.x * dist + spread.x
        t.columns.3.y += fwd.y * dist
        t.columns.3.z += fwd.z * dist + spread.z

        let x = t.columns.3.x
        let z = t.columns.3.z
        t.columns.3.y = snappedYForHorizontalSurface(x: x, z: z, defaultY: t.columns.3.y)

        return t
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

    // MARK: - ARSessionDelegate
    nonisolated func session(_ session: ARSession, didChange geoTrackingStatus: ARGeoTrackingStatus) {
        Task { @MainActor in
            self.isGeoLocalized = (geoTrackingStatus.state == .localized)
            self.reapplyPlacementNearUser()
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        print("AR failed:", error.localizedDescription)
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        print("AR interrupted")
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        print("AR resumed")
    }
}

// MARK: - Compatibility helpers (so older code doesn’t break)
extension ARWhisperCoordinator {

    /// Old call site compatibility — menu-based selection is preferred.
    func setCharacterModelName(_ name: String) {
        // ✅ also sanitize here so old callers can’t set blank
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty == false { self.selectedCharacterModel = cleaned }
        _ = resolvedSelectedModel()
        self.refreshAllCharacters()
        if #available(iOS 14.0, *) {
            self.modelButton?.menu = self.makeModelMenu()
        }
    }

    /// Old call site compatibility — cancels any idle animation subscriptions.
    func stopAllSentinelIdle() {
        for (_, sub) in characterIdleSubs { sub.cancel() }
        characterIdleSubs.removeAll()
    }
}
