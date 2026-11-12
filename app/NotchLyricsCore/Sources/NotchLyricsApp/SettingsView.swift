import AppKit
import AppState
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let model: NowPlayingModel

    var body: some View {
        TabView {
            GeneralSettings(model: model).tabItem { Text("Umum") }
            NotchSettings(settings: model.settings).tabItem { Text("Notch") }
            FloatingSettings(settings: model.settings).tabItem { Text("Lirik Mengambang") }
        }
        .frame(width: 460)
        .padding(20)
    }
}

private struct GeneralSettings: View {
    let model: NowPlayingModel

    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var cacheCleared = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Toggle("Buka saat login", isOn: $launchesAtLogin)
                .onChange(of: launchesAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
            if let launchError {
                Text(launchError).font(.caption).foregroundStyle(.red)
            }
            Toggle("Sorot lirik per kata", isOn: $settings.wordTimingEnabled)
            Stepper(value: $settings.globalOffsetMs, in: -5000...5000, step: 100) {
                LabeledContent("Offset semua lagu", value: "\(settings.globalOffsetMs) ms")
            }
            Text("Nilai positif memunculkan lirik lebih awal. Berguna untuk speaker Bluetooth.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Lirik tersimpan") {
                Button(cacheCleared ? "Sudah dihapus" : "Hapus") {
                    Task {
                        await model.clearCache()
                        cacheCleared = true
                    }
                }
                .disabled(cacheCleared)
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = "Tidak bisa diubah: \(error.localizedDescription)"
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct NotchSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Toggle("Tampilkan notch", isOn: $settings.notchEnabled)
            Toggle("Buka saat kursor di atas notch", isOn: $settings.notchOpensOnHover)
            Toggle("Kecilkan saat lagu dijeda", isOn: $settings.notchCollapsesOnPause)
            Toggle("Cahaya dari sampul album", isOn: $settings.notchArtworkGlow)
            Toggle("Sapaan saat aplikasi dibuka", isOn: $settings.notchGreetingEnabled)
            Toggle("Suara sapaan", isOn: $settings.notchGreetingSoundEnabled)
                .disabled(!settings.notchGreetingEnabled)
            TextField("Nama untuk sapaan", text: $settings.greetingName, prompt: Text("Nama akun Mac"))
                .disabled(!settings.notchGreetingEnabled)
            LabeledContent("Lebar tambahan: \(Int(settings.notchExtraWidth)) pt") {
                Slider(value: $settings.notchExtraWidth, in: -150...300, step: 10)
            }
        }
    }
}

private struct FloatingSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Toggle("Tampilkan lirik mengambang", isOn: $settings.floatingEnabled)
            Toggle("Tampilkan baris berikutnya", isOn: $settings.floatingShowsNextLine)
            LabeledContent("Ukuran huruf: \(Int(settings.floatingFontSize))") {
                Slider(value: $settings.floatingFontSize, in: 14...60, step: 1)
            }
            LabeledContent("Lebar: \(Int(settings.floatingWidth)) pt") {
                Slider(value: $settings.floatingWidth, in: 300...1400, step: 20)
            }
            Picker("Perataan", selection: $settings.floatingAlignment) {
                Text("Kiri").tag(TextAlignmentChoice.left)
                Text("Tengah").tag(TextAlignmentChoice.center)
                Text("Kanan").tag(TextAlignmentChoice.right)
            }
            ColorPicker("Warna teks", selection: colorBinding(\.floatingTextColor))
            ColorPicker("Warna latar", selection: colorBinding(\.floatingBackgroundColor))
            Toggle("Sembunyikan saat lagu dijeda", isOn: $settings.floatingHidesOnPause)
            Toggle("Pudarkan saat kursor di atasnya", isOn: $settings.floatingHidesOnHover)
        }
    }

    private func colorBinding(_ path: ReferenceWritableKeyPath<AppSettings, String>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: ColorCoding.color(from: settings[keyPath: path])) },
            set: { settings[keyPath: path] = ColorCoding.hex(from: NSColor($0)) }
        )
    }
}
