//
//  ARWhisperView.swift
//  EchoTether
//
//  VIEW-ONLY FILE (FULL REWRITE)
//  ✅ Starts/stops LocationManager with AR lifecycle
//  ✅ Configures AR session
//  ✅ Tap gesture
//  ✅ Sidebar button
//  ✅ Character picker button (UIMenu) — no updateUIView hacks needed
//

import SwiftUI
import RealityKit
import ARKit
import CoreLocation
import UIKit

struct ARWhisperView: UIViewRepresentable {

    @EnvironmentObject var locationManager: LocationManager
    @Environment(\.presentationMode) var presentationMode

    func makeCoordinator() -> ARWhisperCoordinator {
        ARWhisperCoordinator(parent: self)
    }

    func makeUIView(context: Context) -> ARView {
        locationManager.start()

        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false
        arView.session.delegate = context.coordinator
        context.coordinator.arView = arView

        // MARK: - AR Configuration
        let lm = CLLocationManager()
        let auth: CLAuthorizationStatus
        if #available(iOS 14.0, *) {
            auth = lm.authorizationStatus
        } else {
            auth = CLLocationManager.authorizationStatus()
        }

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

        // MARK: - Tap Gesture
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(ARWhisperCoordinator.handleTap(_:))
        )
        arView.addGestureRecognizer(tap)

        // MARK: - Sidebar Button
        let sidebarButton = UIButton(type: .system)
        sidebarButton.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 15.0, *) {
            var cfg = UIButton.Configuration.plain()
            cfg.image = UIImage(systemName: "sidebar.right")
            cfg.baseForegroundColor = .white
            cfg.background.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            cfg.background.cornerRadius = 10
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
            sidebarButton.configuration = cfg
        } else {
            sidebarButton.setImage(UIImage(systemName: "sidebar.right"), for: .normal)
            sidebarButton.tintColor = .white
            sidebarButton.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            sidebarButton.layer.cornerRadius = 10
            sidebarButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        }
        sidebarButton.addTarget(
            context.coordinator,
            action: #selector(ARWhisperCoordinator.toggleSidebar),
            for: .touchUpInside
        )
        arView.addSubview(sidebarButton)
        context.coordinator.sidebarButton = sidebarButton

        // MARK: - Model Picker Button
        let modelButton = UIButton(type: .system)
        modelButton.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 15.0, *) {
            var cfg = UIButton.Configuration.plain()
            cfg.image = UIImage(systemName: "person.crop.square")
            cfg.baseForegroundColor = .white
            cfg.background.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            cfg.background.cornerRadius = 10
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
            modelButton.configuration = cfg
        } else {
            modelButton.setImage(UIImage(systemName: "person.crop.square"), for: .normal)
            modelButton.tintColor = .white
            modelButton.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            modelButton.layer.cornerRadius = 10
            modelButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        }

        // ✅ These must match USDZ names in your project (no ".usdz")
        context.coordinator.availableCharacterModels = [
            "Sentinel",
            "MiaDance",
            ""
        ]

        if #available(iOS 14.0, *) {
            modelButton.showsMenuAsPrimaryAction = true
            modelButton.menu = context.coordinator.makeModelMenu()
        }

        arView.addSubview(modelButton)
        context.coordinator.modelButton = modelButton

        NSLayoutConstraint.activate([
            sidebarButton.topAnchor.constraint(equalTo: arView.safeAreaLayoutGuide.topAnchor, constant: 8),
            sidebarButton.trailingAnchor.constraint(equalTo: arView.safeAreaLayoutGuide.trailingAnchor, constant: -8),

            modelButton.topAnchor.constraint(equalTo: arView.safeAreaLayoutGuide.topAnchor, constant: 8),
            modelButton.trailingAnchor.constraint(equalTo: sidebarButton.leadingAnchor, constant: -8)
        ])

        // MARK: - Sidebar UI install
        context.coordinator.installSidebarUI(on: arView)

        // MARK: - Bind systems
        context.coordinator.bindLocation()
        context.coordinator.startListeningToWhispers()

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // No update hacks needed.
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: ARWhisperCoordinator) {
        coordinator.stopListening()
        coordinator.unbindLocation()
        coordinator.stopAllSentinelIdle()
        uiView.session.pause()
        coordinator.parent.locationManager.stop()
    }
}
