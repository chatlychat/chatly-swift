import Foundation
#if canImport(UIKit)
import UIKit

/// Visual theme applied to every Chatly UIKit surface.
///
/// Defaults track the web widget palette so iOS and web feel like one product.
public struct ChatlyTheme {
    /// Brand accent (send button, links, active tab indicator).
    public var primary: UIColor
    /// Window / view background.
    public var bg: UIColor
    /// Primary foreground (body text).
    public var fg: UIColor
    /// Subdued foreground (timestamps, captions).
    public var mutedFg: UIColor
    /// Hairline color for separators and bubble outlines.
    public var border: UIColor

    public init(
        primary: UIColor = ChatlyTheme.color(0x2563EB),
        bg: UIColor = ChatlyTheme.color(0xFFFFFF),
        fg: UIColor = ChatlyTheme.color(0x0F172A),
        mutedFg: UIColor = ChatlyTheme.color(0x64748B),
        border: UIColor = UIColor(red: 15.0 / 255.0,
                                  green: 23.0 / 255.0,
                                  blue: 42.0 / 255.0,
                                  alpha: 0.08)
    ) {
        self.primary = primary
        self.bg = bg
        self.fg = fg
        self.mutedFg = mutedFg
        self.border = border
    }

    /// Builds a fully-opaque UIColor from a 24-bit `0xRRGGBB` integer.
    public static func color(_ hex: UInt32) -> UIColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}
#endif
