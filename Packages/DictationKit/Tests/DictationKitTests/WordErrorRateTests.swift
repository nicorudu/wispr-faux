import Testing
@testable import PostProcessKit

@Suite("WordErrorRate")
struct WordErrorRateTests {
    @Test func ignoresCaseAndPunctuation() {
        #expect(WordErrorRate.compute(reference: "Hello, world.", hypothesis: "hello world") == 0)
        #expect(WordErrorRate.compute(reference: "Don’t stop", hypothesis: "don't stop!") == 0)
    }

    @Test func countsSubstitutionsDeletionsAndInsertions() {
        // One substitution out of four words.
        #expect(WordErrorRate.compute(reference: "send the report today", hypothesis: "send the reports today") == 0.25)
        // One deletion.
        #expect(WordErrorRate.compute(reference: "send the report today", hypothesis: "send report today") == 0.25)
        // Two insertions.
        #expect(WordErrorRate.compute(reference: "send it", hypothesis: "please send it now") == 1)
    }

    @Test func emptyInputs() {
        #expect(WordErrorRate.compute(reference: "", hypothesis: "") == 0)
        #expect(WordErrorRate.compute(reference: "", hypothesis: "thank you") == 1)
        #expect(WordErrorRate.compute(reference: "hello there", hypothesis: "") == 1)
    }
}
