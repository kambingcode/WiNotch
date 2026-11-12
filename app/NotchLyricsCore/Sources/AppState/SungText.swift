import SwiftUI

/// A lyric line with the words reached so far at full strength and the rest dim.
public enum SungText {
    private static let unsungOpacity = 0.4

    /// `sung` counts characters. Nil shows the whole line at full strength.
    public static func attributed(_ text: String, sung: Int?, color: Color) -> AttributedString {
        var result = AttributedString(text)
        guard let sung else {
            result.foregroundColor = color
            return result
        }
        let boundary = text.index(text.startIndex, offsetBy: sung, limitedBy: text.endIndex) ?? text.endIndex
        var reached = AttributedString(text[..<boundary])
        var remaining = AttributedString(text[boundary...])
        reached.foregroundColor = color
        remaining.foregroundColor = color.opacity(unsungOpacity)
        result = reached + remaining
        return result
    }
}
