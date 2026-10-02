import Testing
@testable import HushCore

@Test func overrideBeatsBuiltInDefault() {
    // Slack is .casual in the built-in map; a user override of .minimal wins.
    #expect(StyleResolver.resolve(
        bundleID: "com.tinyspeck.slackmacgap",
        overrides: ["com.tinyspeck.slackmacgap": .minimal]) == .minimal)
}

@Test func builtInDefaultsMatchPlanTable() {
    // T10 bundle IDs — one representative per group.
    #expect(StyleResolver.resolve(bundleID: "com.hnc.Discord", overrides: [:]) == .casual)
    #expect(StyleResolver.resolve(bundleID: "ru.keepcoder.Telegram", overrides: [:]) == .casual)
    #expect(StyleResolver.resolve(bundleID: "com.apple.mail", overrides: [:]) == .formal)
    #expect(StyleResolver.resolve(bundleID: "com.microsoft.Outlook", overrides: [:]) == .formal)
    #expect(StyleResolver.resolve(bundleID: "com.apple.dt.Xcode", overrides: [:]) == .minimal)
    #expect(StyleResolver.resolve(bundleID: "com.todesktop.230313mzl4w4u92", overrides: [:]) == .minimal)
    #expect(StyleResolver.resolve(bundleID: "com.mitchellh.ghostty", overrides: [:]) == .minimal)
}

@Test func unknownAppGetsDefault() {
    #expect(StyleResolver.resolve(bundleID: "com.unknown.Editor", overrides: [:]) == .default)
}

@Test func nilBundleIDGetsDefault() {
    #expect(StyleResolver.resolve(bundleID: nil, overrides: [:]) == .default)
    // Even with overrides present, a nil bundle ID can't look them up.
    #expect(StyleResolver.resolve(
        bundleID: nil,
        overrides: ["com.apple.mail": .minimal]) == .default)
}
