import Testing
@testable import Dictionary

private func engine(_ rules: [(String, String)], terms: [String] = [])
    -> ReplacementEngine {
    let e = ReplacementEngine()
    e.update(rules: rules.enumerated().map { i, pair in
        ReplacementRule(entryID: "r\(i)", from: pair.0, to: pair.1)
    }, terms: terms)
    return e
}

// MARK: - apply (T8: whole-word, case-insensitive, longest-first)

@Test func singleWordReplacement() {
    let e = engine([("super base", "Supabase")])
    #expect(e.apply("I use super base daily") == "I use Supabase daily")
}

@Test func multiWordFrom() {
    let e = engine([("super base", "Supabase")])
    #expect(e.apply("point it at super base now") == "point it at Supabase now")
}

@Test func caseInsensitive() {
    let e = engine([("supabase", "Supabase")])
    #expect(e.apply("supabase and SUPABASE") == "Supabase and Supabase")
}

@Test func longestFromFirst() {
    // "super base" must win over the shorter "base" — applying the short
    // rule first would split the phrase.
    let e = engine([("base", "B"), ("super base", "Supabase")])
    #expect(e.apply("use super base") == "use Supabase")
}

@Test func overlapOrdering() {
    // Longest-first: "a b c" beats "a b" even when both could match.
    let e = engine([("a b", "X"), ("a b c", "Y")])
    #expect(e.apply("a b c") == "Y")
    #expect(e.apply("a b d") == "X d")
}

@Test func wordBoundaries() {
    let e = engine([("gw", "gue")])
    // Whole word only — never inside a larger word.
    #expect(e.apply("gw") == "gue")
    #expect(e.apply("gwen") == "gwen")
    #expect(e.apply("gw itu") == "gue itu")
    // Apostrophes and underscores count as word chars.
    let e2 = engine([("don", "done")])
    #expect(e2.apply("don't stop") == "don't stop")
    let e3 = engine([("foo", "bar")])
    #expect(e3.apply("foo_bar") == "foo_bar")
    // Punctuation boundaries still match.
    #expect(e3.apply("(foo), foo!") == "(bar), bar!")
}

@Test func indonesianText() {
    let e = engine([("besok", "tomorrow"), ("udah", "sudah")])
    #expect(e.apply("besok kita udah deploy")
            == "tomorrow kita sudah deploy")
}

@Test func noRulesIsIdentity() {
    let e = ReplacementEngine()
    #expect(e.apply("unchanged text") == "unchanged text")
}

// MARK: - hits

@Test func hitCountsAccumulatePerEntry() {
    let e = engine([("a", "A"), ("b", "B")])
    _ = e.apply("a a a")
    _ = e.apply("b")
    #expect(e.takeHits() == ["r0": 3, "r1": 1])
    // Drained — a second take is empty.
    #expect(e.takeHits().isEmpty)
}

@Test func hitsNeedEntryID() {
    let e = ReplacementEngine()
    e.update(rules: [ReplacementRule(from: "x", to: "y")], terms: [])
    _ = e.apply("x")
    #expect(e.takeHits().isEmpty)
}

@Test func termsSnapshot() {
    let e = engine([("a", "B")], terms: ["B", "Supabase"])
    #expect(e.dictionaryTerms == ["B", "Supabase"])
}
