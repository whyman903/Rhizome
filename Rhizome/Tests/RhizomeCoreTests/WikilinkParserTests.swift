import Foundation
import XCTest
@testable import RhizomeCore

final class WikilinkParserTests: XCTestCase {
    func testParsesPlainTextAsSingleRun() {
        XCTAssertEqual(WikilinkParser.parse("Just a sentence."), [.text("Just a sentence.")])
    }

    func testParsesSingleWikilinkInContext() {
        let runs = WikilinkParser.parse("See [[Foo]] for more.")
        XCTAssertEqual(
            runs,
            [
                .text("See "),
                .link(target: "Foo", display: "Foo"),
                .text(" for more."),
            ]
        )
    }

    func testParsesWikilinkWithAlias() {
        let runs = WikilinkParser.parse("Read [[wiki/sources/Foo.md|this source]] now.")
        XCTAssertEqual(
            runs,
            [
                .text("Read "),
                .link(target: "wiki/sources/Foo.md", display: "this source"),
                .text(" now."),
            ]
        )
    }

    func testParsesMultipleWikilinksInOneString() {
        let runs = WikilinkParser.parse("Compare [[A]] with [[B]].")
        XCTAssertEqual(
            runs,
            [
                .text("Compare "),
                .link(target: "A", display: "A"),
                .text(" with "),
                .link(target: "B", display: "B"),
                .text("."),
            ]
        )
    }

    func testIgnoresEmptyTargetBrackets() {
        let runs = WikilinkParser.parse("Text [[]] end")
        XCTAssertEqual(runs.count, 1)
        if case .text(let str) = runs[0] {
            XCTAssertEqual(str, "Text [[]] end")
        } else {
            XCTFail("expected single text run, got \(runs)")
        }
    }

    func testLinkAtStartAndEndAreRetained() {
        let runs = WikilinkParser.parse("[[Start]] middle [[End]]")
        XCTAssertEqual(
            runs,
            [
                .link(target: "Start", display: "Start"),
                .text(" middle "),
                .link(target: "End", display: "End"),
            ]
        )
    }

    func testLinkURLRoundTripsTarget() {
        let url = WikilinkParser.linkURL(for: "wiki/sources/With Spaces.md")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.scheme, "rhizome")
        XCTAssertEqual(WikilinkParser.decodeLinkURL(url!), "wiki/sources/With Spaces.md")
    }

    func testDecodeLinkURLReturnsNilForForeignURL() {
        let url = URL(string: "https://example.com")!
        XCTAssertNil(WikilinkParser.decodeLinkURL(url))
    }
}
