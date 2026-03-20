import XCTest
@testable import SwiftBot

final class PatchyValidationTests: XCTestCase {
    
    @MainActor
    func testPatchyErrorDiagnosticMapping() async {
        let app = AppModel()
        
        // Test 50001 (Missing Access)
        let error50001 = NSError(domain: "test", code: 403, userInfo: [
            "statusCode": 403,
            "responseBody": "{\"message\": \"Missing Access\", \"code\": 50001}"
        ])
        XCTAssertEqual(app.patchyErrorDiagnostic(from: error50001), 
                       "SwiftBot cannot view this channel. Check permissions in the Discord server.")
        
        // Test 50013 (Missing Permissions)
        let error50013 = NSError(domain: "test", code: 403, userInfo: [
            "statusCode": 403,
            "responseBody": "{\"message\": \"Missing Permissions\", \"code\": 50013}"
        ])
        XCTAssertEqual(app.patchyErrorDiagnostic(from: error50013), 
                       "SwiftBot lacks 'Embed Links' or 'Mention' permissions in this channel.")
        
        // Test 10003 (Unknown Channel)
        let error10003 = NSError(domain: "test", code: 404, userInfo: [
            "statusCode": 404,
            "responseBody": "{\"message\": \"Unknown Channel\", \"code\": 10003}"
        ])
        XCTAssertEqual(app.patchyErrorDiagnostic(from: error10003), 
                       "Channel not found. It may have been deleted — please remove or update this target.")
        
        // Test 401 (Unauthorized)
        let error401 = NSError(domain: "test", code: 401, userInfo: ["statusCode": 401])
        XCTAssertEqual(app.patchyErrorDiagnostic(from: error401), 
                       "Invalid Bot Token. Please check your token in General Settings.")
        
        // Test 429 (Rate Limited)
        let error429 = NSError(domain: "test", code: 429, userInfo: ["statusCode": 429])
        XCTAssertEqual(app.patchyErrorDiagnostic(from: error429), 
                       "Sending too fast. Discord is temporarily limiting requests.")
        
        // Test Fallback
        let errorGeneric = NSError(domain: "test", code: 500, userInfo: ["statusCode": 500])
        XCTAssertEqual(app.patchyErrorDiagnostic(from: errorGeneric), 
                       "Failed to send (HTTP 500). Check Patchy logs for details.")

        // Test vendor fetch error keeps localized description instead of fake HTTP 0 send error
        XCTAssertEqual(
            app.patchyErrorDiagnostic(from: AMDServiceError.invalidResponse),
            "AMD endpoint returned an invalid response object."
        )

        // Test network error is surfaced as a network problem
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertEqual(
            app.patchyErrorDiagnostic(from: timeout),
            "Network request timed out while contacting the update source."
        )
    }
}
