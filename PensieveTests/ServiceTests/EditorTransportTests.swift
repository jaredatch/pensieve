import XCTest
@testable import Pensieve

final class EditorTransportTests: XCTestCase {
    func testHostilePayloadEncodesWithoutRawScriptCloseAndRoundTrips() throws {
        let hostile = "`</script>` ${x} \"q\" ' \n# heading"
        let encoded = EditorTransport.jsonString(for: hostile)

        XCTAssertFalse(encoded.contains("</script>"))

        let data = try XCTUnwrap(encoded.data(using: .utf8))
        let decoded = try JSONDecoder().decode(String.self, from: data)
        XCTAssertEqual(decoded, hostile)
    }

    func testEdgeStringsRoundTrip() throws {
        let values = ["", "\"", "\\", "\n\t", "emoji 🧪 𝌆"]

        for value in values {
            let encoded = EditorTransport.jsonString(for: value)
            let data = try XCTUnwrap(encoded.data(using: .utf8))
            let decoded = try JSONDecoder().decode(String.self, from: data)
            XCTAssertEqual(decoded, value)
        }
    }
}
