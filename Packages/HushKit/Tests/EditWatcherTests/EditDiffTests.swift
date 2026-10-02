import Foundation
import Testing
@testable import EditWatcher

// MARK: - EditDiff.candidates (plan T9 rules, exactly)

@Test func singleTokenSubstitution() {
    let found = EditDiff.candidates(
        inserted: "meet at super base office",
        edited: "meet at Supabase office")
    #expect(found == [Replacement(from: "super", to: "Supabase")]
            || found == [Replacement(from: "super base", to: "Supabase")])
}

@Test func wordForWord() {
    let found = EditDiff.candidates(
        inserted: "the teh report",
        edited: "the the report")
    #expect(found == [Replacement(from: "teh", to: "the")])
}

@Test func multiTokenSubstitutionWithinBounds() {
    // 2→2 and 3→1 substitutions are kept.
    #expect(EditDiff.candidates(inserted: "a b c d e f g h",
                                edited: "a b X Y f g h") .isEmpty == false)
    let f = EditDiff.candidates(inserted: "a b c d e f g h i j",
                                edited: "a b c d X Y f g h i j")
    #expect(f == [Replacement(from: "e", to: "X Y")] || f.contains(Replacement(from: "e", to: "X Y")))
}

@Test func substitutionTooLargeIsSkipped() {
    // 4-token replacement run is over the 1–3 limit.
    let found = EditDiff.candidates(
        inserted: "keep a b c d tail end here",
        edited: "keep X Y tail end here")
    #expect(found.isEmpty)
}

@Test func moreThanThirtyPercentChangedYieldsNothing() {
    // 4 of 5 tokens change → over the 30% cutoff.
    let found = EditDiff.candidates(
        inserted: "one two three four five",
        edited: "one A B C D")
    #expect(found.isEmpty)
}

@Test func punctuationOnlyIsIgnored() {
    #expect(EditDiff.candidates(inserted: "send it now",
                                edited: "send it now.").isEmpty)
    #expect(EditDiff.candidates(inserted: "hello world",
                                edited: "hello, world").isEmpty)
}

@Test func caseOnlySingleTokenIsKept() {
    let found = EditDiff.candidates(inserted: "use supabase here",
                                  edited: "use Supabase here")
    #expect(found == [Replacement(from: "supabase", to: "Supabase")])
}

@Test func pureInsertionOrDeletionIsNotACandidate() {
    // Text appended after the paste — nothing was substituted.
    #expect(EditDiff.candidates(inserted: "hello world",
                                edited: "hello world and more text").isEmpty)
}

// MARK: - InsertedSpan.locate

@Test func locateVerbatim() {
    let v = "before some inserted text after"
    let inserted = "inserted text"
    let end = ("before some " as NSString).length + inserted.utf16.count
    #expect(InsertedSpan.locate(inserted: inserted, endOffset: end, in: v)
            == inserted)
}

@Test func locateEditedNearOffset() {
    let v = "before some Supabase text after"
    let inserted = "some inserted text"
    let end = ("before " as NSString).length + inserted.utf16.count
    // "inserted" → "Supabase" in place; the span is found and the diff
    // surfaces the substitution.
    let span = InsertedSpan.locate(inserted: inserted, endOffset: end, in: v)
    #expect(span != nil)
    if let span {
        let c = EditDiff.candidates(inserted: inserted.trimmingCharacters(in: .whitespaces),
                                    edited: span)
        #expect(c.contains(Replacement(from: "inserted", to: "Supabase")))
    }
}

@Test func locateAbortsWhenSpanGone() {
    // Everything after the caret moved — the original text is nowhere near
    // the offset.
    #expect(InsertedSpan.locate(inserted: "the cat sat",
                                endOffset: 15,
                                in: "something else entirely") == nil)
}

@Test func locateAbortsWhenOffsetOutOfRange() {
    #expect(InsertedSpan.locate(inserted: "abc", endOffset: 50, in: "short") == nil)
}
