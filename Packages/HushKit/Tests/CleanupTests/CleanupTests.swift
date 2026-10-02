import Foundation
import Testing
@testable import Cleanup
import HushCore

// MARK: - CleanupPrompt

@Test func promptOmitsTermsLineWhenEmpty() {
    let prompt = CleanupPrompt.system(style: .default, terms: [])
    #expect(!prompt.contains("Spell these terms"))
    #expect(prompt.hasSuffix("Style: Clear, neutral sentences."))
    #expect(prompt.contains("You clean up dictated speech transcripts."))
    #expect(prompt.contains("Never translate."))
}

@Test func promptIncludesTermsLineWhenPresent() {
    let prompt = CleanupPrompt.system(style: .casual, terms: ["Supabase", "Hush"])
    #expect(prompt.contains("- Spell these terms exactly: Supabase, Hush"))
    #expect(prompt.hasSuffix("Style: Casual chat message. Keep slang. Do not add greetings or sign-offs."))
}

@Test func styleLinesMatchTable() {
    #expect(CleanupPrompt.styleLine(.default) == "Clear, neutral sentences.")
    #expect(CleanupPrompt.styleLine(.casual) == "Casual chat message. Keep slang. Do not add greetings or sign-offs.")
    #expect(CleanupPrompt.styleLine(.formal) == "Polished, professional writing suitable for email. Do not add greetings or sign-offs the speaker did not say.")
    #expect(CleanupPrompt.styleLine(.minimal) == "Only remove fillers and add punctuation. Do not change any other word, its casing, or any symbol, identifier or code.")
}

@Test func userMessageWrapsTranscript() {
    #expect(CleanupPrompt.user("hello world") == "<transcript>hello world</transcript>")
}

// MARK: - CleanupGuard

@Test func guardPassesNormalOutput() {
    let raw = "um so like we should deploy after lunch"
    let out = "So we should deploy after lunch."
    #expect(CleanupGuard.normalize(out, raw: raw) == out)
}

@Test func guardFailsOnEmptyOutput() {
    #expect(CleanupGuard.normalize("", raw: "some words here") == nil)
    #expect(CleanupGuard.normalize("   \n", raw: "some words here") == nil)
}

@Test func guardRatioBounds() {
    let raw = "one two three four five six seven eight nine ten"
    // Outputs that drop raw words now fail the coverage check (covered below).
    // Upper ratio bound still fires on expansion: 15 / 10 = 1.5 — boundary passes.
    #expect(CleanupGuard.normalize(
        "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen",
        raw: raw) != nil)
    // 16 / 10 = 1.6 — above.
    #expect(CleanupGuard.normalize(
        "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen",
        raw: raw) == nil)
}

@Test func guardCoverageDropsLostContent() {
    // The real Gemma failure: trailing "after lunch" dropped. Content tokens:
    // jadi besok kita deploy ke production ya after lunch (9); output matches 6 → 0.67.
    let raw = "eh jadi um besok kita deploy ke production ya, uh, after lunch"
    #expect(CleanupGuard.normalize("besok kita deploy ke production ya", raw: raw) == nil)
    let good = "Besok kita deploy ke production ya, after lunch."
    #expect(CleanupGuard.normalize(good, raw: raw) == good)
}

@Test func guardCoverageAllowsSelfCorrection() {
    // "Thursday, no" is a self-correction the cleaner may drop: 6 of 8 content
    // tokens survive → exactly 0.75, at the boundary → passes.
    let raw = "um move it to Thursday, no, Friday at 3"
    #expect(CleanupGuard.normalize("Move it to Friday at 3.", raw: raw)
        == "Move it to Friday at 3.")
}

@Test func guardCoverageIsAMultiset() {
    let raw = "buy milk milk milk please"
    // Each output token is consumed once: one "milk" can't cover three.
    #expect(CleanupGuard.normalize("Buy milk, please.", raw: raw) == nil)
    #expect(CleanupGuard.normalize("Buy milk, milk, milk, please.", raw: raw) != nil)
}

@Test func guardCoverageAllowsListFormatting() {
    // The real Qwen miss: ordinals + discourse markers dropped for list formatting.
    // "okay", "first", "second", "and", "third" are droppable → all remaining
    // content tokens ("the three things we need are …" ×list items) are covered.
    let raw = "okay the three things we need are, um, first the login page, second the dashboard, and third the settings screen"
    let out = "The three things we need are:\n- the login page\n- the dashboard\n- the settings screen"
    #expect(CleanupGuard.normalize(out, raw: raw) == out)
    // Content tokens still can't be dropped: the "after lunch" case stays a fallback.
    let lunchRaw = "eh jadi um besok kita deploy ke production ya, uh, after lunch"
    #expect(CleanupGuard.normalize("besok kita deploy ke production ya", raw: lunchRaw) == nil)
}

@Test func guardCoverageSkipsFillerOnlyRaw() {
    // Raw with no content tokens → coverage check is skipped.
    #expect(CleanupGuard.normalize("um", raw: "um uh") == "um")
}

@Test func guardStripsEchoedTranscriptTagsAndQuotes() {
    #expect(CleanupGuard.normalize("<transcript>raw text here</transcript>", raw: "raw text here")
        == "raw text here")
    #expect(CleanupGuard.normalize("\"raw text here\"", raw: "raw text here")
        == "raw text here")
    #expect(CleanupGuard.normalize("“raw text here”", raw: "raw text here")
        == "raw text here")
}

// MARK: - CleanupGuard.isClean (LLM fast path)

// Real user raw transcripts (from /tmp/hush-lang recordings) that need no LLM:
// already punctuated, no fillers, no repeats, no corrections.
@Test func isCleanAcceptsRealCleanTranscripts() {
    #expect(CleanupGuard.isClean("Is there any way to improve the cleanup?"))
    #expect(CleanupGuard.isClean("Is there any way to improve the processing for the cleanup?"))
    #expect(CleanupGuard.isClean(
        "This is a testing for campuran bahasa so I think this should be bagus ya."))
    #expect(CleanupGuard.isClean(
        "The RAW and clean up version is the same also for the WAV is not working " +
        "and the building wall is not working because when I try to use two language " +
        "at the same recording it's always translated it to Bahasa Indonesia"))
    #expect(CleanupGuard.isClean("Nanti kita rapat jam tiga sore."))
    #expect(CleanupGuard.isClean(""))
}

@Test func isCleanRejectsFillers() {
    #expect(!CleanupGuard.isClean("um so like we should deploy after lunch"))
    #expect(!CleanupGuard.isClean("it is, hmm, complicated"))
    #expect(!CleanupGuard.isClean("emm anu kayak gitu"))
}

@Test func isCleanRejectsRepeatedWordsAndPhrases() {
    // Real user raw: back-to-back repeated trigram.
    #expect(!CleanupGuard.isClean(
        "dan juga kenapa prosesnya sangat lalu prosesnya sangat lalu " +
        "ketika saya menggunakan langsung penggunaan"))
    #expect(!CleanupGuard.isClean("Testing, testing, testing"))
    #expect(!CleanupGuard.isClean("I want the the report"))
    #expect(!CleanupGuard.isClean("we need to to fix this"))
    // Repeated but NOT back-to-back stays clean.
    #expect(CleanupGuard.isClean(
        "the wave is not working and the building wall is not working either"))
}

@Test func isCleanRejectsSelfCorrectionCues() {
    #expect(!CleanupGuard.isClean("move it to Thursday, I mean Friday"))
    #expect(!CleanupGuard.isClean("no wait that's wrong"))
    #expect(!CleanupGuard.isClean("besok, maksudnya lusa"))
    #expect(!CleanupGuard.isClean("eh maksud saya hari Jumat"))
    #expect(!CleanupGuard.isClean("sorry, I meant three o'clock"))
    // Ordinary negations are not correction cues.
    #expect(CleanupGuard.isClean("ini bukan masalah besar"))
    #expect(CleanupGuard.isClean("there is no problem with that"))
}

// MARK: - GuardedCleaner

actor StubCleaner: Cleaner {
    var output: String
    var delay: TimeInterval = 0
    var throwError: (any Error)?
    init(output: String, delay: TimeInterval = 0, throwError: (any Error)? = nil) {
        self.output = output
        self.delay = delay
        self.throwError = throwError
    }
    func prepare() async throws {}
    func clean(_ raw: String, style: CleanupStyle, terms: [String]) async throws -> String {
        if let throwError { throw throwError }
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        return output
    }
}

// The raws below start with a filler so they don't take the clean-input fast
// path and actually reach the inner cleaner.
private let messyRaw = "um one two three four five"

@Test func guardedCleanerFallsBackOnBadRatio() async {
    let cleaner = GuardedCleaner(StubCleaner(output: "x"))
    // "x" is 1 word vs raw 6 → ratio 0.17 → fallback to rule-processed raw.
    let result = try? await cleaner.clean(messyRaw, style: .default, terms: [])
    #expect(result == messyRaw)
    #expect(await cleaner.lastCleanupFellBack == true)
}

@Test func guardedCleanerPassesThroughGoodOutput() async {
    let cleaner = GuardedCleaner(StubCleaner(output: "Um, one two three four five."))
    let result = try? await cleaner.clean(messyRaw, style: .default, terms: [])
    #expect(result == "Um, one two three four five.")
    #expect(await cleaner.lastCleanupFellBack == false)
}

@Test func guardedCleanerFallsBackOnThrow() async {
    struct StubError: Error {}
    let cleaner = GuardedCleaner(StubCleaner(output: "", throwError: StubError()))
    let result = try? await cleaner.clean(messyRaw, style: .default, terms: [])
    #expect(result == messyRaw)
    #expect(await cleaner.lastCleanupFellBack == true)
}

@Test func guardedCleanerFallsBackOnTimeout() async {
    let cleaner = GuardedCleaner(StubCleaner(output: "irrelevant", delay: 2), timeout: 0.2)
    let start = Date()
    let result = try? await cleaner.clean(messyRaw, style: .default, terms: [])
    #expect(result == messyRaw)
    #expect(await cleaner.lastCleanupFellBack == true)
    #expect(Date().timeIntervalSince(start) < 1.0)  // didn't wait the full 2 s
}

@Test func guardedCleanerSkipsLLMForCleanInput() async {
    let inner = StubCleaner(output: "SHOULD NOT BE USED")
    let cleaner = GuardedCleaner(inner)
    let raw = "Is there any way to improve the cleanup?"
    let result = try? await cleaner.clean(raw, style: .default, terms: [])
    #expect(result == raw)
    #expect(await cleaner.lastCleanupFellBack == false)
    #expect(await cleaner.lastCleanupRun?.usedLLM == false)
    // Casual/minimal also skip; only formal always rewrites.
    _ = try? await cleaner.clean(raw, style: .casual, terms: [])
    #expect(await cleaner.lastCleanupRun?.usedLLM == false)
    _ = try? await cleaner.clean(raw, style: .minimal, terms: [])
    #expect(await cleaner.lastCleanupRun?.usedLLM == false)
}

@Test func guardedCleanerRunsLLMForFormalStyle() async {
    let raw = "Is there any way to improve the cleanup?"
    let cleaner = GuardedCleaner(StubCleaner(output: raw))
    let result = try? await cleaner.clean(raw, style: .formal, terms: [])
    #expect(result == raw)
    #expect(await cleaner.lastCleanupFellBack == false)
    #expect(await cleaner.lastCleanupRun?.usedLLM == true)
}

@Test func guardedCleanerRunsLLMForMessyInput() async {
    let raw = "um I want the the thing deployed"
    let cleaner = GuardedCleaner(StubCleaner(output: raw))
    let result = try? await cleaner.clean(raw, style: .default, terms: [])
    #expect(result == raw)
    #expect(await cleaner.lastCleanupRun?.usedLLM == true)
}

@Test func guardedCleanerAllowsRepeatedStartRemoval() async throws {
    let raw = "the... sorry... the... side panel"
    let cleaned = "The side panel."
    let cleaner = GuardedCleaner(StubCleaner(output: cleaned))
    #expect(try await cleaner.clean(raw, style: .default, terms: []) == cleaned)
    #expect(await cleaner.lastCleanupFellBack == false)
}

@Test func guardStillProtectsApologiesAndContentAfterRestarts() {
    // A genuine apology is content, not an interruption between repeated starts.
    #expect(CleanupGuard.normalize("The report is ready.",
        raw: "I'm sorry I missed the meeting. The report is ready.") == nil)
    // Legitimate restart removal must not hide the loss of the trailing instruction.
    #expect(CleanupGuard.normalize("The side panel.",
        raw: "the... sorry... the... side panel should show the microphone and app status") == nil)
}

@Test func guardDoesNotTreatRepeatedPronounInApologyAsRestart() {
    #expect(CleanupGuard.normalize("I'm late.", raw: "I'm sorry I'm late.") == nil)
}
