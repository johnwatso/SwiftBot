import Foundation
import XCTest
@testable import UpdateEngine

final class NVIDIAServiceTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        NVIDIAMockURLProtocol.requestHandler = nil
    }

    func testFetchLatestDriverIncludesReleaseHighlights() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NVIDIAMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let apiEndpoint = URL(string: "https://example.com/nvidia-driver-api")!

        let releaseNotesHTML = """
        <strong>Game Ready for Forza Horizon 6</strong><br>
        <br>
        This new Game Ready Driver provides the best gaming experience for Forza Horizon 6 and Subnautica 2.<br>
        <br>
        <strong>Fixed Gaming Bugs</strong><br>
        <ul>
          <li>Enhanced smoothness when DLSS Frame Generation is used with V-SYNC. [5999586]</li>
        </ul>
        <strong>Fixed General Bugs</strong><br>
        <ul>
          <li>Foundry Mari viewport displays flickering. [6102981]</li>
        </ul>
        """

        NVIDIAMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, apiEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            let body = requestBody(from: request)
            XCTAssertTrue(body.contains("pfid=929"))

            let payload: [String: Any] = [
                "IDS": [
                    [
                        "downloadInfo": [
                            "Version": "596.49",
                            "ReleaseDateTime": "Tue Mar 10, 2026",
                            "NameLocalized": "GeForce Game Ready Driver",
                            "DetailsURL": "https://www.nvidia.com/en-us/drivers/details/270391/",
                            "DownloadURL": "https://us.download.nvidia.com/Windows/596.49/596.49-desktop-win10-win11.exe",
                            "DownloadURLFileSize": "957.32 MB",
                            "DisplayVersion": "596.49",
                            "IsWHQL": "1",
                            "IsDC": "1",
                            "ReleaseNotes": releaseNotesHTML,
                            "OSList": [
                                ["OSName": "Windows 10 64-bit"],
                                ["OSName": "Windows 11"]
                            ]
                        ]
                    ]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            return (
                HTTPURLResponse(url: apiEndpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let service = NVIDIAService(session: session, apiEndpoint: apiEndpoint)
        let driver = try await service.fetchLatestDriver()

        XCTAssertEqual(driver.releaseNotes.sections.first?.title, "Release Highlights")
        XCTAssertTrue(driver.releaseNotes.sections.first?.bullets.first?.text.contains("Game Ready for Forza Horizon 6") == true)
        XCTAssertTrue(driver.embedJSON.contains("Release Highlights"))
        XCTAssertTrue(driver.embedJSON.contains("https://www.nvidia.com/en-us/drivers/details/270391/"))
        XCTAssertTrue(driver.embedJSON.contains(#""name" : "Version""#))
        XCTAssertTrue(driver.embedJSON.contains(#""name" : "Release Date""#))
        XCTAssertFalse(driver.embedJSON.contains(#""name" : "Size""#))
        XCTAssertFalse(driver.embedJSON.contains(#""name" : "OS""#))
        XCTAssertFalse(driver.embedJSON.contains(#""name" : "Package""#))
        XCTAssertFalse(driver.embedJSON.contains(#""name" : "Download""#))
        XCTAssertFalse(driver.embedJSON.contains(#""name" : "Driver Details""#))
    }
}

private func requestBody(from request: URLRequest) -> String {
    if let body = request.httpBody {
        return String(data: body, encoding: .utf8) ?? ""
    }

    guard let stream = request.httpBodyStream else { return "" }
    stream.open()
    defer { stream.close() }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return String(data: data, encoding: .utf8) ?? ""
}

private final class NVIDIAMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("Missing request handler for NVIDIAMockURLProtocol.")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
