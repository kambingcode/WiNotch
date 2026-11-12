import AppKit
import AppState
import FloatingUI
import NotchUI
import PlaybackCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = NowPlayingModel.live()
    private lazy var notch = NotchWindowController(model: model)
    private lazy var floating = FloatingLyricsController(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        notch.show()
        floating.start()
        model.start()
    }
}

@main
struct NotchLyricsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("WiNotch", systemImage: "music.note") {
            StatusMenu(model: delegate.model)
        }
        Window("Pengaturan WiNotch", id: WindowID.settings) {
            SettingsView(model: delegate.model)
        }
        .windowResizability(.contentSize)
        Window("Cari Lirik", id: WindowID.search) {
            SearchView(model: delegate.model)
        }
        .windowResizability(.contentSize)
    }
}

enum WindowID {
    static let settings = "settings"
    static let search = "search"
}

private struct StatusMenu: View {
    @Bindable var model: NowPlayingModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var settings = model.settings
        Text(statusText)
        if !model.blockedPlayers.isEmpty {
            Button("Buka Pengaturan Izin…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            }
        }
        Divider()
        Toggle("Lirik Mengambang", isOn: $settings.floatingEnabled)
        Divider()
        Text("Offset lagu ini: \(model.offset, format: .number.precision(.fractionLength(1))) dtk")
        Button("Lirik Lebih Awal 0,1 dtk") { model.adjustOffset(by: 0.1) }
            .keyboardShortcut("]")
        Button("Lirik Lebih Lambat 0,1 dtk") { model.adjustOffset(by: -0.1) }
            .keyboardShortcut("[")
        Divider()
        Button("Cari Lirik…") { open(WindowID.search) }
            .disabled(model.track == nil)
        Button("Pengaturan…") { open(WindowID.settings) }
            .keyboardShortcut(",")
        Divider()
        Button("Keluar") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var statusText: String {
        if let blocked = model.blockedPlayers.first {
            return "WiNotch belum diizinkan mengontrol \(blocked.rawValue)"
        }
        switch model.status {
        case .idle: return "Putar lagu di Spotify"
        case .searching: return "Mencari lirik…"
        case .found(let source): return "Lirik dari \(source) · \(model.hasWordTiming ? "per kata" : "per baris")"
        case .notFound: return "Lirik tidak ditemukan"
        case .unavailable: return "Layanan lirik tidak terjangkau"
        }
    }
}
