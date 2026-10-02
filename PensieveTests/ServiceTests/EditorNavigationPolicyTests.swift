import WebKit
import XCTest
@testable import Pensieve

final class EditorNavigationPolicyTests: XCTestCase {
    func testInitialPrivateSchemeLoadIsAllowed() throws {
        let url = try XCTUnwrap(URL(string: "pensieve-editor://app/index.html"))

        XCTAssertEqual(
            EditorNavigationPolicy.decision(
                for: url,
                navigationType: .other,
                scheme: "pensieve-editor"
            ),
            .allowInitialLoad
        )
    }

    func testHTTPLinkActivationOpensExternally() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))

        XCTAssertEqual(
            EditorNavigationPolicy.decision(
                for: url,
                navigationType: .linkActivated,
                scheme: "pensieve-editor"
            ),
            .openExternally
        )
    }

    func testFileAndJavaScriptLinkActivationsAreCancelled() throws {
        let fileURL = try XCTUnwrap(URL(string: "file:///tmp/secret"))
        let javascriptURL = try XCTUnwrap(URL(string: "javascript:alert(1)"))

        XCTAssertEqual(
            EditorNavigationPolicy.decision(
                for: fileURL,
                navigationType: .linkActivated,
                scheme: "pensieve-editor"
            ),
            .cancel
        )
        XCTAssertEqual(
            EditorNavigationPolicy.decision(
                for: javascriptURL,
                navigationType: .linkActivated,
                scheme: "pensieve-editor"
            ),
            .cancel
        )
    }

    func testNonInitialPrivateSchemeLoadIsCancelled() throws {
        let url = try XCTUnwrap(URL(string: "pensieve-editor://app/editor.bundle.js"))

        XCTAssertEqual(
            EditorNavigationPolicy.decision(
                for: url,
                navigationType: .linkActivated,
                scheme: "pensieve-editor"
            ),
            .cancel
        )
    }
}
