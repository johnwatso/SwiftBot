import XCTest
@testable import SwiftBot

/// Guards the license notices that have to ship inside the app bundle. If a
/// dependency is added without re-running
/// `scripts/generate_third_party_notices.py`, this fails rather than shipping an
/// incomplete notice file.
final class ThirdPartyNoticesTests: XCTestCase {

    /// Every package pinned in Package.resolved, by the display name the
    /// generator writes into the notices.
    private static let expectedPackages = [
        "Sparkle",
        "SwiftSoup",
        "swift-opus",
        "SwiftNIO",
        "SwiftNIO SSL",
        "Swift Crypto",
        "Swift Certificates",
        "Swift ASN.1",
        "Swift Markdown",
        "swift-cmark",
        "Swift Atomics",
        "Swift Collections",
        "Swift System",
        "libdave-swift"
    ]

    func testNoticesShipInsideTheAppBundle() throws {
        let notices = try XCTUnwrap(
            AcknowledgementsView.loadNotices(),
            "THIRD-PARTY-NOTICES.md must be bundled — the licenses require it to accompany the app"
        )
        XCTAssertGreaterThan(notices.count, 10_000, "Notices look truncated")
    }

    func testEveryDependencyHasASection() throws {
        let notices = try XCTUnwrap(AcknowledgementsView.loadNotices())
        for package in Self.expectedPackages {
            XCTAssertTrue(
                notices.contains("## \(package)\n"),
                "No notice section for \(package) — re-run scripts/generate_third_party_notices.py"
            )
        }
    }

    func testApacheLicenceTextIsIncludedInFull() throws {
        let notices = try XCTUnwrap(AcknowledgementsView.loadNotices())
        // Apache-2.0 requires the license text itself to travel with the binary,
        // not just a reference to it.
        XCTAssertTrue(notices.contains("Appendix A: Apache License 2.0"))
        XCTAssertTrue(notices.contains("TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION"))
        XCTAssertTrue(notices.contains("Applies to: SwiftNIO"))
    }

    func testLibdaveIsRecordedAsUnresolvedRatherThanAsserted() throws {
        let notices = try XCTUnwrap(AcknowledgementsView.loadNotices())
        // The bundled Dave.xcframework's component licenses were never captured,
        // so the notices must say so rather than guess at MIT/Apache/OpenSSL.
        XCTAssertTrue(notices.contains("bundled framework's license status is unresolved"))
        XCTAssertTrue(notices.contains("Its own Swift source is MIT licensed"))
        XCTAssertFalse(
            notices.contains("mlspp is licensed"),
            "Do not assert licenses for the native components — they are not recorded upstream"
        )
    }

    func testNoticesAreReadableAsPlainText() throws {
        let notices = try XCTUnwrap(AcknowledgementsView.loadNotices())
        // The Acknowledgements window renders this verbatim, so HTML would leak
        // through as literal tags.
        XCTAssertFalse(notices.contains("<details>"))
        XCTAssertFalse(notices.contains("<summary>"))
    }
}
