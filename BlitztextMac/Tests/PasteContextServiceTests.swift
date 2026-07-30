import XCTest

/// Covers the leading-space decision table. The Accessibility lookup itself
/// needs a live focused text element and is exercised manually.
final class PasteContextServiceTests: XCTestCase {
    func testSentenceEndingPunctuationNeedsASpace() {
        for character in [".", "!", "?", ":", ";", ",", ")", "]", "}"] as [Character] {
            XCTAssertTrue(
                PasteContextService.needsLeadingSpace(after: character),
                "a transcript must not stick to \(character)"
            )
        }
    }

    func testWordCharactersNeedASpace() {
        for character in ["a", "Z", "9", "\u{00E4}", "\u{00DF}"] as [Character] {
            XCTAssertTrue(PasteContextService.needsLeadingSpace(after: character))
        }
    }

    func testWhitespaceNeedsNoSpace() {
        for character in [" ", "\t", "\n", "\r"] as [Character] {
            XCTAssertFalse(
                PasteContextService.needsLeadingSpace(after: character),
                "\(character.debugDescription) already separates"
            )
        }
    }

    func testOpeningDelimitersNeedNoSpace() {
        for character in ["(", "[", "{", "\u{201E}", "\u{00AB}", "\"", "'", "/", "-"] as [Character] {
            XCTAssertFalse(
                PasteContextService.needsLeadingSpace(after: character),
                "text follows \(character) directly"
            )
        }
    }
}
