import AppState
import LyricsFinder
import SwiftUI

/// Lets the user pick lyrics when the automatic choice is wrong or missing.
struct SearchView: View {
    let model: NowPlayingModel

    @State private var title = ""
    @State private var artist = ""
    @State private var results: [LyricsCandidate] = []
    @State private var isSearching = false
    @State private var searched = false
    @State private var usedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Judul", text: $title)
                TextField("Artis", text: $artist)
                Button("Cari") { search() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.isEmpty || isSearching)
            }
            if isSearching {
                ProgressView().frame(maxWidth: .infinity)
            } else if searched, results.isEmpty {
                Text("Tidak ada hasil. Coba ubah judul atau artis.").foregroundStyle(.secondary)
            }
            List(results) { result in
                row(result)
            }
            .frame(height: 320)
        }
        .padding(16)
        .frame(width: 560)
        .onAppear(perform: fillFromCurrentSong)
        .onChange(of: model.track?.id) { _, _ in fillFromCurrentSong() }
    }

    private func row(_ result: LyricsCandidate) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title.isEmpty ? "Tanpa judul" : result.title).lineLimit(1)
                Text(details(result)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if result.isLikelyMatch {
                Text("Cocok").font(.caption).foregroundStyle(.green)
            }
            Button(usedID == result.id ? "Dipakai" : "Pakai") {
                usedID = result.id
                Task { await model.use(result) }
            }
            .disabled(usedID == result.id)
        }
    }

    private func details(_ result: LyricsCandidate) -> String {
        var parts = [result.artist, result.source, "\(result.lineCount) baris"]
        if let length = result.length {
            parts.append(String(format: "%d:%02d", Int(length) / 60, Int(length) % 60))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func fillFromCurrentSong() {
        title = model.track?.title ?? ""
        artist = model.track?.artist ?? ""
        results = []
        searched = false
        usedID = nil
    }

    private func search() {
        isSearching = true
        Task {
            results = await model.search(title: title, artist: artist)
            isSearching = false
            searched = true
        }
    }
}
