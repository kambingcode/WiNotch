import AppKit
import Observation

/// Holds the album cover and its colours once per song, so every view shows
/// them instantly instead of loading them again in the middle of an animation.
@MainActor
@Observable
final class ArtworkStore {
    private(set) var image: NSImage?
    private(set) var colors: [ArtworkPalette.Color] = [.white]

    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var task: Task<Void, Never>?

    func load(_ next: URL?) {
        guard next != url else { return }
        url = next
        task?.cancel()
        image = nil
        colors = [.white]
        guard let next else { return }
        task = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: next), !Task.isCancelled else { return }
            let loaded = await Task.detached { () -> (NSImage, [ArtworkPalette.Color])? in
                guard let image = NSImage(data: data),
                      let cover = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                return (image, ArtworkPalette.glowColors(from: ArtworkPalette.colors(from: cover)))
            }.value
            guard let loaded, !Task.isCancelled else { return }
            self?.image = loaded.0
            self?.colors = loaded.1
        }
    }
}
