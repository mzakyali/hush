import Testing
@testable import HushCore

// MARK: - WordDiff.compute

@Test func wordDiffIdentical() {
    let ops = WordDiff.compute(old: "hello world", new: "hello world")
    #expect(ops == [.same("hello"), .same("world")])
}

@Test func wordDiffRemovedWord() {
    // Filler removed by cleanup.
    let ops = WordDiff.compute(old: "so uh we ship it", new: "so we ship it")
    #expect(ops == [.same("so"), .removed("uh"), .same("we"), .same("ship"), .same("it")])
}

@Test func wordDiffAddedWord() {
    let ops = WordDiff.compute(old: "lets go", new: "lets all go")
    #expect(ops == [.same("lets"), .added("all"), .same("go")])
}

@Test func wordDiffReplacedWord() {
    // A changed word surfaces as removed + added neighbours.
    let ops = WordDiff.compute(old: "colour it", new: "color it")
    #expect(ops == [.removed("colour"), .added("color"), .same("it")])
}

@Test func wordDiffIndonesian() {
    let ops = WordDiff.compute(
        old: "nanti kita emm rapat jam tiga",
        new: "nanti kita rapat jam tiga"
    )
    #expect(ops == [.same("nanti"), .same("kita"), .removed("emm"),
                    .same("rapat"), .same("jam"), .same("tiga")])
}

@Test func wordDiffPunctuationChange() {
    // A punctuation-only change coalesces: render the new token, not a
    // struck-out twin of the old one.
    let ops = WordDiff.compute(old: "send it please", new: "send it, please")
    #expect(ops == [.same("send"), .changed(old: "it", new: "it,"), .same("please")])
}

@Test func wordDiffCoalescesCaseAndPunctuationSwaps() {
    // "ship"→"Ship" and "off"→"off." collapse to .changed; genuinely different
    // neighbours ("the"→"—") stay removed+added.
    let ops = WordDiff.compute(
        old: "um ship it the the build is green and QA signed off",
        new: "Ship it — the build is green and QA signed off.")
    #expect(ops == [
        .removed("um"), .changed(old: "ship", new: "Ship"), .same("it"),
        .removed("the"), .added("—"), .same("the"), .same("build"),
        .same("is"), .same("green"), .same("and"), .same("QA"),
        .same("signed"), .changed(old: "off", new: "off.")
    ])
}

@Test func wordDiffCoalesceRejectsEmptyNormalised() {
    // A punctuation-only token normalises to "" — never a word swap.
    let ops = WordDiff.compute(old: "the — end", new: "the – end")
    #expect(ops == [.same("the"), .removed("—"), .added("–"), .same("end")])
}

@Test func wordDiffEmptySides() {
    #expect(WordDiff.compute(old: "", new: "") == [])
    #expect(WordDiff.compute(old: "", new: "a b") == [.added("a"), .added("b")])
    #expect(WordDiff.compute(old: "a b", new: "") == [.removed("a"), .removed("b")])
    // Extra whitespace collapses — no phantom ops.
    #expect(WordDiff.compute(old: "a   b", new: "a b") == [.same("a"), .same("b")])
}

@Test func wordDiffReordering() {
    // LCS keeps the longest common run; ties break toward removing first, so
    // the moved word surfaces as removed+added around the common run.
    let ops = WordDiff.compute(old: "a b c d", new: "a c b d")
    #expect(ops == [.same("a"), .removed("b"), .same("c"), .added("b"), .same("d")])
}
