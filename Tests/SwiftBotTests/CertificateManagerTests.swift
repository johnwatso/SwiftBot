import Foundation
import XCTest
@testable import SwiftBot

final class CertificateManagerTests: XCTestCase {
    func testHTTPSDomainNormalizationStripsSchemeAndWhitespace() {
        var settings = AdminWebUISettings()
        settings.httpsDomain = "  https://Admin.Example.com/dashboard  "

        XCTAssertEqual(settings.normalizedHTTPSDomain, "admin.example.com")
    }

    func testCloudflareZoneCandidatesWalkDownDomainLabels() {
        XCTAssertEqual(
            CloudflareDNSProvider.zoneCandidates(for: "_acme-challenge.api.dev.example.com"),
            [
                "_acme-challenge.api.dev.example.com",
                "api.dev.example.com",
                "dev.example.com",
                "example.com",
                "com"
            ]
        )
    }

    func testCertificateRenewalWindowUsesThirtyDays() {
        let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let renewSoon = referenceDate.addingTimeInterval(29 * 24 * 60 * 60)
        let renewLater = referenceDate.addingTimeInterval(31 * 24 * 60 * 60)

        XCTAssertTrue(CertificateManager.shouldRenew(expiresAt: renewSoon, referenceDate: referenceDate))
        XCTAssertFalse(CertificateManager.shouldRenew(expiresAt: renewLater, referenceDate: referenceDate))
    }

    func testAutomaticHTTPSValidationSummaryRequiresCloudflareChecks() {
        XCTAssertEqual(
            CertificateManager.validationSummaryState(
                tokenIsValid: true,
                zoneFound: true,
                dnsRecordFound: true,
                hostnameResolves: true
            ),
            .success
        )

        XCTAssertEqual(
            CertificateManager.validationSummaryState(
                tokenIsValid: true,
                zoneFound: true,
                dnsRecordFound: true,
                hostnameResolves: false
            ),
            .warning
        )

        XCTAssertEqual(
            CertificateManager.validationSummaryState(
                tokenIsValid: true,
                zoneFound: false,
                dnsRecordFound: true,
                hostnameResolves: true
            ),
            .error
        )
    }
}
