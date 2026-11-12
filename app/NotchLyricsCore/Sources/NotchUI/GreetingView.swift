import AppKit
import AppState
import PlaybackCore
import SwiftUI

/// What the greeting shows at each moment, counted from when the notch starts
/// to drop. A plain function of time, so every pose can be tested.
enum GreetingTimeline {
    static let duration: TimeInterval = 9.15
    private static let eyesOpen: TimeInterval = 0.85
    private static let textAppears: TimeInterval = 5.65

    /// The chord fades for about as long as the text stays.
    static let sounds: [(time: TimeInterval, file: String)] = [
        (eyesOpen, "greeting-pop"),
        (textAppears, "greeting-bloom"),
    ]
    /// A closed eye is a thin line, because it would otherwise have no height to draw.
    private static let closedOpenness = 0.08

    struct Pose: Equatable {
        var eyesOpacity = 0.0
        /// Left at -1, right at 1.
        var glance = 0.0
        var openness = 1.0
        var smile = 0.0
        var textOpacity = 0.0
    }

    static func pose(at time: TimeInterval, reducesMotion: Bool = false) -> Pose {
        func ramp(_ start: TimeInterval, _ end: TimeInterval) -> Double {
            let progress = min(max((time - start) / (end - start), 0), 1)
            return progress * progress * (3 - 2 * progress)
        }
        if reducesMotion {
            return Pose(textOpacity: ramp(0.5, 1.1))
        }
        let opened = ramp(eyesOpen, eyesOpen + 0.1) - (ramp(3.25, 3.5) - ramp(3.5, 3.75))
        return Pose(
            eyesOpacity: ramp(0.5, 0.8) - ramp(5.6, 6.15),
            glance: 2 * ramp(1.95, 2.45) - ramp(1.25, 1.65) - ramp(2.75, 3.1),
            openness: closedOpenness + (1 - closedOpenness) * opened,
            smile: ramp(4, 4.6),
            textOpacity: ramp(textAppears, textAppears + 0.5)
        )
    }
}

/// An upright oval that a rising lower lid pushes into a smiling arch.
struct GreetingEye: Shape {
    var openness: CGFloat
    var smile: CGFloat

    private static let steps = 32
    private static let ovalWidth: CGFloat = 0.6
    private static let archHeight: CGFloat = 0.3
    private static let archThickness: CGFloat = 0.24

    func path(in rect: CGRect) -> Path {
        func blend(_ from: CGFloat, _ to: CGFloat) -> CGFloat { from + (to - from) * smile }
        let halfWidth = rect.width / 2 * blend(Self.ovalWidth, 1)
        let halfHeight = rect.height / 2 * openness
        let arch = rect.height * Self.archHeight
        let thickness = rect.height * Self.archThickness

        /// Across the eye from -1 to 1, closer together near the tips, where it curves most.
        let across = (0...Self.steps).map { -cos(CGFloat($0) / CGFloat(Self.steps) * .pi) }
        func point(_ position: CGFloat, upper: Bool) -> CGPoint {
            let edge = sqrt(max(1 - position * position, 0))
            let archCentre = arch / 2 - arch * (1 - position * position)
            let oval = halfHeight * edge * (upper ? -1 : 1)
            let smiling = archCentre + thickness / 2 * edge * (upper ? -1 : 1)
            return CGPoint(x: rect.midX + position * halfWidth, y: rect.midY + blend(oval, smiling))
        }

        var path = Path()
        path.addLines(across.map { point($0, upper: true) } + across.reversed().map { point($0, upper: false) })
        path.closeSubpath()
        return path
    }
}

@MainActor
private enum GreetingSound {
    /// Held so that a sound cannot be released while it plays.
    private static var playing: [NSSound] = []

    /// Plays nothing when run outside the app bundle, which has the sound files.
    static func play(_ file: String) {
        guard let url = Bundle.main.url(forResource: file, withExtension: "wav"),
              let sound = NSSound(contentsOf: url, byReference: true) else { return }
        playing.append(sound)
        sound.play()
    }
}

/// A one-off, so redrawing every frame costs only these few seconds.
struct GreetingContent: View {
    let model: NowPlayingModel
    let notchHeight: CGFloat

    private static let eyeSize = CGSize(width: 16, height: 23)
    private static let eyeGap: CGFloat = 15
    private static let glanceDistance: CGFloat = 4

    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSince(start)
            let pose = GreetingTimeline.pose(at: time, reducesMotion: reducesMotion)
            ZStack {
                eyes(pose)
                Text(model.settings.greeting())
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 14)
                    .opacity(pose.textOpacity)
                    .blur(radius: (1 - pose.textOpacity) * 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, notchHeight)
        }
        .task { await playSounds() }
    }

    /// Without the eyes there is no moment for the sounds to mark.
    private func playSounds() async {
        guard !reducesMotion else { return }
        for sound in GreetingTimeline.sounds {
            let wait = sound.time - Date().timeIntervalSince(start)
            try? await Task.sleep(for: .seconds(max(wait, 0)))
            guard !Task.isCancelled else { return }
            // Asked each time, because the player may answer after the app starts.
            if model.settings.notchGreetingSoundEnabled, !model.playback.isPlaying {
                GreetingSound.play(sound.file)
            }
        }
    }

    private func eyes(_ pose: GreetingTimeline.Pose) -> some View {
        let eye = GreetingEye(openness: pose.openness, smile: pose.smile)
            .fill(.white)
            .frame(width: Self.eyeSize.width, height: Self.eyeSize.height)
        return HStack(spacing: Self.eyeGap) {
            eye
            eye
        }
        .shadow(color: .white.opacity(0.7), radius: 4)
        .shadow(color: .white.opacity(0.35), radius: 10)
        .offset(x: pose.glance * Self.glanceDistance)
        .opacity(pose.eyesOpacity)
        .blur(radius: (1 - pose.eyesOpacity) * 4)
    }
}
