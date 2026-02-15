//
//  SplashView..swift
//  EchoTether
//
//  Created by Bobby Smith on 1/31/26.
//

import SwiftUI
import Lottie

struct SplashView: View {
    let onFinish: () -> Void

    @State private var didFinish = false

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            LottieView(animation: .named("echotether_logo_lottie"))
                .playing(loopMode: .playOnce)
                .scaledToFit()
                .frame(width: 320, height: 320)
        }
        .onAppear {
            // echotether_logo_lottie.json = 120 frames @ 60fps => 2.0 seconds
            guard !didFinish else { return }
            didFinish = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                onFinish()
            }
        }
    }
}


