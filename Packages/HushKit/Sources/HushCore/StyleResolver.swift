import Foundation

/// §3 item 7 / plan T10: the cleanup style for the app that is frontmost when
/// recording stops. Resolution order: user override (`app_styles`) → built-in
/// map → `.default`.
public enum StyleResolver {
    /// Built-in defaults by bundle ID — the plan T10 table verbatim.
    public static let builtInDefaults: [String: CleanupStyle] = [
        // casual
        "com.tinyspeck.slackmacgap": .casual,   // Slack
        "net.whatsapp.WhatsApp": .casual,
        "com.hnc.Discord": .casual,
        "com.apple.MobileSMS": .casual,          // Messages
        "ru.keepcoder.Telegram": .casual,
        // formal
        "com.apple.mail": .formal,
        "com.microsoft.Outlook": .formal,
        // minimal
        "com.apple.dt.Xcode": .minimal,
        "com.microsoft.VSCode": .minimal,
        "com.exafunction.windsurf": .minimal,
        "com.todesktop.230313mzl4w4u92": .minimal,  // Cursor
        "com.apple.Terminal": .minimal,
        "com.googlecode.iterm2": .minimal,
        "com.mitchellh.ghostty": .minimal,
    ]

    public static func resolve(bundleID: String?,
                               overrides: [String: CleanupStyle]) -> CleanupStyle {
        guard let bundleID else { return .default }
        if let override = overrides[bundleID] { return override }
        return builtInDefaults[bundleID] ?? .default
    }
}
