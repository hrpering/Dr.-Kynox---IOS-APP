import SwiftUI
import AVFoundation
import AudioToolbox
import UIKit

#if canImport(Lottie)
import Lottie
#endif

enum IntroMotionVariant {
    case short
    case long

    var videoName: String {
        switch self {
        case .short: return "intro_short"
        case .long: return "intro_long"
        }
    }

    var lottieName: String {
        switch self {
        case .short: return "intro_orb_short"
        case .long: return "intro_orb_long"
        }
    }
}

private func mediaResourceURL(name: String, ext: String) -> URL? {
    Bundle.main.url(forResource: name, withExtension: ext) ??
    Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Media") ??
    Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Media/Sounds") ??
    Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Media/Lottie")
}

struct IntroMotionCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let variant: IntroMotionVariant

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            if let player {
                LoopingPlayerLayerView(player: player)
                    .onAppear {
                        guard !reduceMotion else { return }
                        player.seek(to: .zero)
                        player.play()
                    }
                    .onDisappear {
                        player.pause()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)) { _ in
                        player.seek(to: .zero)
                        if !reduceMotion {
                            player.play()
                        }
                    }
            } else {
                LinearGradient(
                    colors: [AppColor.primaryLight, AppColor.surface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            LinearGradient(
                colors: [Color.clear, AppColor.primary.opacity(0.12)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    LottieOrbView(name: variant.lottieName, size: 92)
                        .padding(12)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AppColor.border, lineWidth: 1)
        )
        .task {
            if player == nil {
                player = buildPlayer()
            }
        }
    }

    private func buildPlayer() -> AVPlayer? {
        guard let url = mediaResourceURL(name: variant.videoName, ext: "mp4") ??
                mediaResourceURL(name: "intro", ext: "mp4") else {
            return nil
        }
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = AVPlayer.ActionAtItemEnd.none
        return player
    }
}

private struct LoopingPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerContainerView {
        let view = PlayerLayerContainerView()
        view.backgroundColor = .clear
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerLayerContainerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

private final class PlayerLayerContainerView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

struct LottieOrbView: View {
    let name: String
    var size: CGFloat = 72

    var body: some View {
#if canImport(Lottie)
        LottieLoopRepresentable(name: name)
            .frame(width: size, height: size)
            .background(Color.white.opacity(0.55))
            .clipShape(Circle())
            .overlay(Circle().stroke(AppColor.primary.opacity(0.22), lineWidth: 1))
#else
        Circle()
            .fill(AppColor.primaryLight)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "waveform.path")
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(AppColor.primary)
            )
#endif
    }
}

#if canImport(Lottie)
private struct LottieLoopRepresentable: UIViewRepresentable {
    let name: String

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.backgroundColor = .clear

        let animationView = LottieAnimationView()
        animationView.translatesAutoresizingMaskIntoConstraints = false
        animationView.contentMode = .scaleAspectFit
        animationView.loopMode = .loop
        animationView.backgroundBehavior = .pauseAndRestore

        if let animation = loadAnimation(named: name) {
            animationView.animation = animation
            animationView.play()
        }

        container.addSubview(animationView)
        NSLayoutConstraint.activate([
            animationView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            animationView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            animationView.topAnchor.constraint(equalTo: container.topAnchor),
            animationView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        context.coordinator.animationView = animationView
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let animationView = context.coordinator.animationView else { return }
        if animationView.animation == nil, let animation = loadAnimation(named: name) {
            animationView.animation = animation
            animationView.play()
        }
        if !animationView.isAnimationPlaying {
            animationView.play()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var animationView: LottieAnimationView?
    }

    private func loadAnimation(named: String) -> LottieAnimation? {
        LottieAnimation.named(named, bundle: .main) ??
        LottieAnimation.named(named, bundle: .main, subdirectory: "Media/Lottie")
    }
}
#endif

enum UISoundCue: String {
    case tap = "ui_tap"
    case success = "ui_success"
    case error = "ui_error"
}

@MainActor
final class UISoundEngine {
    static let shared = UISoundEngine()

    private var soundIDs: [UISoundCue: SystemSoundID] = [:]
    private var ambientPlayer: AVAudioPlayer?
    private var hasPreloaded = false

    private init() {}

    func preloadIfNeeded() {
        guard !hasPreloaded else { return }
        hasPreloaded = true

        for cue in [UISoundCue.tap, .success, .error] {
            guard let url = mediaResourceURL(name: cue.rawValue, ext: "wav") else {
                continue
            }
            var soundID: SystemSoundID = 0
            AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
            soundIDs[cue] = soundID
        }

        if let ambientURL = mediaResourceURL(name: "ambient_bed", ext: "wav") {
            ambientPlayer = try? AVAudioPlayer(contentsOf: ambientURL)
            ambientPlayer?.numberOfLoops = -1
            ambientPlayer?.volume = 0.08
            ambientPlayer?.prepareToPlay()
        }
    }

    func play(_ cue: UISoundCue) {
        preloadIfNeeded()
        guard UIApplication.shared.applicationState == .active else { return }
        guard let id = soundIDs[cue] else { return }
        AudioServicesPlaySystemSound(id)
    }

    func startAmbientIfNeeded() {
        preloadIfNeeded()
        guard UIApplication.shared.applicationState == .active else { return }
        ambientPlayer?.play()
    }

    func stopAmbient() {
        ambientPlayer?.pause()
    }

    deinit {
        for id in soundIDs.values {
            AudioServicesDisposeSystemSoundID(id)
        }
    }
}
