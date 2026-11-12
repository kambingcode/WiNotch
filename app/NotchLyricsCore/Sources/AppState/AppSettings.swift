import AppKit
import Observation

public enum TextAlignmentChoice: String, CaseIterable, Sendable {
    case left, center, right
}

/// The user's preferences, saved as they change.
@MainActor
@Observable
public final class AppSettings {
    private enum Key {
        static let globalOffset = "globalOffsetMs"
        static let wordTimingEnabled = "wordTimingEnabled"
        static let notchEnabled = "notchEnabled"
        static let notchOpensOnHover = "notchOpensOnHover"
        static let notchCollapsesOnPause = "notchCollapsesOnPause"
        static let notchExtraWidth = "notchExtraWidth"
        static let notchArtworkGlow = "notchArtworkGlow"
        static let notchGreetingEnabled = "notchGreetingEnabled"
        static let notchGreetingSoundEnabled = "notchGreetingSoundEnabled"
        static let greetingName = "greetingName"
        static let floatingEnabled = "floatingEnabled"
        static let floatingFontSize = "floatingFontSize"
        static let floatingWidth = "floatingWidth"
        static let floatingAlignment = "floatingAlignment"
        static let floatingTextColor = "floatingTextColor"
        static let floatingBackgroundColor = "floatingBackgroundColor"
        static let floatingShowsNextLine = "floatingShowsNextLine"
        static let floatingHidesOnPause = "floatingHidesOnPause"
        static let floatingHidesOnHover = "floatingHidesOnHover"
        static let floatingPositionX = "floatingPositionX"
        static let floatingPositionY = "floatingPositionY"
    }

    /// Applied to every song, in milliseconds. Positive shows lines earlier.
    public var globalOffsetMs: Int { didSet { defaults.set(globalOffsetMs, forKey: Key.globalOffset) } }

    /// Highlights each word as it is sung, where the lyrics allow it.
    public var wordTimingEnabled: Bool { didSet { defaults.set(wordTimingEnabled, forKey: Key.wordTimingEnabled) } }

    public var notchEnabled: Bool { didSet { defaults.set(notchEnabled, forKey: Key.notchEnabled) } }
    public var notchOpensOnHover: Bool { didSet { defaults.set(notchOpensOnHover, forKey: Key.notchOpensOnHover) } }
    public var notchCollapsesOnPause: Bool { didSet { defaults.set(notchCollapsesOnPause, forKey: Key.notchCollapsesOnPause) } }
    public var notchExtraWidth: Double { didSet { defaults.set(notchExtraWidth, forKey: Key.notchExtraWidth) } }
    public var notchArtworkGlow: Bool { didSet { defaults.set(notchArtworkGlow, forKey: Key.notchArtworkGlow) } }
    public var notchGreetingEnabled: Bool { didSet { defaults.set(notchGreetingEnabled, forKey: Key.notchGreetingEnabled) } }
    public var notchGreetingSoundEnabled: Bool {
        didSet { defaults.set(notchGreetingSoundEnabled, forKey: Key.notchGreetingSoundEnabled) }
    }
    /// Empty uses the first name of the Mac's account.
    public var greetingName: String { didSet { defaults.set(greetingName, forKey: Key.greetingName) } }

    public var floatingEnabled: Bool { didSet { defaults.set(floatingEnabled, forKey: Key.floatingEnabled) } }
    public var floatingFontSize: Double { didSet { defaults.set(floatingFontSize, forKey: Key.floatingFontSize) } }
    public var floatingWidth: Double { didSet { defaults.set(floatingWidth, forKey: Key.floatingWidth) } }
    public var floatingAlignment: TextAlignmentChoice {
        didSet { defaults.set(floatingAlignment.rawValue, forKey: Key.floatingAlignment) }
    }
    public var floatingTextColor: String { didSet { defaults.set(floatingTextColor, forKey: Key.floatingTextColor) } }
    public var floatingBackgroundColor: String {
        didSet { defaults.set(floatingBackgroundColor, forKey: Key.floatingBackgroundColor) }
    }
    public var floatingShowsNextLine: Bool { didSet { defaults.set(floatingShowsNextLine, forKey: Key.floatingShowsNextLine) } }
    public var floatingHidesOnPause: Bool { didSet { defaults.set(floatingHidesOnPause, forKey: Key.floatingHidesOnPause) } }
    public var floatingHidesOnHover: Bool { didSet { defaults.set(floatingHidesOnHover, forKey: Key.floatingHidesOnHover) } }

    /// Nil until the user has moved the window.
    public var floatingPosition: CGPoint? {
        didSet {
            defaults.set(floatingPosition?.x, forKey: Key.floatingPositionX)
            defaults.set(floatingPosition?.y, forKey: Key.floatingPositionY)
        }
    }

    /// The words the notch says when the app starts.
    public func greeting(accountName: String = NSFullUserName()) -> String {
        let chosen = greetingName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = chosen.isEmpty ? accountName.split(separator: " ").first.map(String.init) ?? "" : chosen
        return name.isEmpty ? "Hello, Welcome!" : "Hello, Welcome \(name)!"
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        func double(_ key: String, _ fallback: Double) -> Double {
            defaults.object(forKey: key) as? Double ?? fallback
        }
        globalOffsetMs = defaults.integer(forKey: Key.globalOffset)
        wordTimingEnabled = bool(Key.wordTimingEnabled, true)
        notchEnabled = bool(Key.notchEnabled, true)
        notchOpensOnHover = bool(Key.notchOpensOnHover, true)
        notchCollapsesOnPause = bool(Key.notchCollapsesOnPause, true)
        notchExtraWidth = double(Key.notchExtraWidth, 0)
        notchArtworkGlow = bool(Key.notchArtworkGlow, true)
        notchGreetingEnabled = bool(Key.notchGreetingEnabled, true)
        notchGreetingSoundEnabled = bool(Key.notchGreetingSoundEnabled, true)
        greetingName = defaults.string(forKey: Key.greetingName) ?? ""
        floatingEnabled = bool(Key.floatingEnabled, false)
        floatingFontSize = double(Key.floatingFontSize, 26)
        floatingWidth = double(Key.floatingWidth, 640)
        floatingAlignment = defaults.string(forKey: Key.floatingAlignment)
            .flatMap(TextAlignmentChoice.init(rawValue:)) ?? .center
        floatingTextColor = defaults.string(forKey: Key.floatingTextColor) ?? "#FFFFFFFF"
        floatingBackgroundColor = defaults.string(forKey: Key.floatingBackgroundColor) ?? "#000000B3"
        floatingShowsNextLine = bool(Key.floatingShowsNextLine, true)
        floatingHidesOnPause = bool(Key.floatingHidesOnPause, true)
        floatingHidesOnHover = bool(Key.floatingHidesOnHover, false)
        if let x = defaults.object(forKey: Key.floatingPositionX) as? Double,
           let y = defaults.object(forKey: Key.floatingPositionY) as? Double {
            floatingPosition = CGPoint(x: x, y: y)
        }
    }
}

/// Colours stored as #RRGGBBAA text.
public enum ColorCoding {
    public static func color(from hex: String) -> NSColor {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 8, let value = UInt32(digits, radix: 16) else { return .white }
        func channel(_ shift: UInt32) -> CGFloat { CGFloat((value >> shift) & 0xFF) / 255 }
        return NSColor(srgbRed: channel(24), green: channel(16), blue: channel(8), alpha: channel(0))
    }

    public static func hex(from color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? .white
        func byte(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X%02X",
            byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent), byte(rgb.alphaComponent)
        )
    }
}
