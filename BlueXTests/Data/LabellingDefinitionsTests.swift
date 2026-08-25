import XCTest
@testable import BlueX

/// Guards against the interface, the LLM prompts and `docs/labelling/definitions.md`
/// silently drifting apart. Every verbatim sentence/bullet held in
/// `LabellingDefinitions` must appear, character-for-character (modulo the `*`/`**`
/// markdown emphasis markers, which are stripped before comparing on both sides), in
/// the committed markdown file — the actual source of truth. A definition that
/// differs between the Swift code and the document is worse than no definition.
final class LabellingDefinitionsTests: XCTestCase {

    /// `#filePath` for this test file is
    /// `.../bluex-v2/BlueXTests/Data/LabellingDefinitionsTests.swift`; the repo root
    /// is two directories up from `BlueXTests/Data`.
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LabellingDefinitionsTests.swift
            .deletingLastPathComponent() // Data
            .deletingLastPathComponent() // BlueXTests
    }

    private func markdownText() throws -> String {
        let path = repoRoot().appendingPathComponent("docs/labelling/definitions.md")
        return try String(contentsOf: path, encoding: .utf8)
    }

    /// Strips markdown emphasis markers (`**`, `*`) and normalizes whitespace
    /// (including line wrapping, which differs between the 80-column markdown source
    /// and a Swift multi-line literal) so a Swift string that omits formatting still
    /// matches the markdown's verbatim prose word-for-word.
    private func stripEmphasis(_ text: String) -> String {
        let noEmphasis = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            // Markdown blockquote marker ("> " at the start of each wrapped line) —
            // strip so a quoted, line-wrapped blockquote still matches the Swift
            // literal's unwrapped prose.
            .replacingOccurrences(of: "> ", with: "")
        let collapsed = noEmphasis.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    private func assertVerbatim(_ text: String, in markdown: String, _ label: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            stripEmphasis(markdown).contains(stripEmphasis(text)),
            "\(label) does not appear verbatim in docs/labelling/definitions.md: \(text)",
            file: file, line: line
        )
    }

    func testVersionMatchesDocument() {
        XCTAssertEqual(LabellingDefinitions.version, 1)
    }

    func testHateDefinitionIsVerbatim() throws {
        let markdown = try markdownText()
        assertVerbatim(LabellingDefinitions.hate.definition, in: markdown, "hate.definition")
    }

    func testHateNotThisBulletsAreVerbatim() throws {
        let markdown = try markdownText()
        XCTAssertFalse(LabellingDefinitions.hate.notThis.isEmpty)
        for bullet in LabellingDefinitions.hate.notThis {
            assertVerbatim(bullet, in: markdown, "hate.notThis")
        }
    }

    func testCounterDefinitionIsVerbatim() throws {
        let markdown = try markdownText()
        assertVerbatim(LabellingDefinitions.counter.definition, in: markdown, "counter.definition")
    }

    func testCounterNotThisBulletsAreVerbatim() throws {
        let markdown = try markdownText()
        XCTAssertFalse(LabellingDefinitions.counter.notThis.isEmpty)
        for bullet in LabellingDefinitions.counter.notThis {
            assertVerbatim(bullet, in: markdown, "counter.notThis")
        }
    }

    func testNeutralDefinitionIsVerbatim() throws {
        let markdown = try markdownText()
        assertVerbatim(LabellingDefinitions.neutral.definition, in: markdown, "neutral.definition")
    }

    func testSkipDefinitionIsVerbatim() throws {
        let markdown = try markdownText()
        assertVerbatim(LabellingDefinitions.skip.definition, in: markdown, "skip.definition")
    }

    func testApplyingNotesAreVerbatim() throws {
        let markdown = try markdownText()
        XCTAssertFalse(LabellingDefinitions.applyingNotes.isEmpty)
        for note in LabellingDefinitions.applyingNotes {
            assertVerbatim(note, in: markdown, "applyingNotes")
        }
    }

    func testAllContainsExactlyTheFourClasses() {
        XCTAssertEqual(LabellingDefinitions.all.map { $0.key }, [1, 2, 3, 0])
        XCTAssertEqual(LabellingDefinitions.all.map { $0.name }, ["hate", "counter", "neutral", "skip"])
    }
}
