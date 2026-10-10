import XCTest

@MainActor
func XCTAssertThrowsErrorAsync<Value>(
    _ expression: @autoclosure () async throws -> Value,
    file: StaticString = #filePath, line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch { errorHandler(error) }
}
