import XCTest
@testable import SwiftBot

/// Ruru short-code normalization, validated locally before calling RuruPairing.
final class RuruPairingCodeTests: XCTestCase {
    func testShortCodesAreRecognisedLeniently() {
        XCTAssertEqual(RuruPairingCode.normalized("mvcp 6jh9"), "MVCP-6JH9")
        XCTAssertEqual(RuruPairingCode.normalized(" MVCP-6JH9\n"), "MVCP-6JH9")
        XCTAssertNil(RuruPairingCode.normalized("MVCP-6JH0"), "0 is not in Ruru's alphabet")
        XCTAssertNil(RuruPairingCode.normalized("MVCP-6JH"))
        XCTAssertNil(RuruPairingCode.normalized("RURU1:eyJ2ZXJzaW9uIjoxfQ"))
    }
}
