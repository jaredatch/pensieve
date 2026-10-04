import Darwin
import XCTest

enum FileServiceErrorAssertions {
    static func hiddenCopyTemporary(_ error: Error, destination: String, code: Int32,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let failure = error as NSError
        let temporary = failure.userInfo[NSFilePathErrorKey] as? String ?? ""
        let parent = URL(fileURLWithPath: destination).deletingLastPathComponent().path
        XCTAssertEqual(failure.domain, NSPOSIXErrorDomain, file: file, line: line)
        XCTAssertEqual(failure.code, Int(code), file: file, line: line)
        XCTAssertTrue(temporary.hasPrefix(parent + "/.pensieve-copy-"), temporary, file: file, line: line)
        XCTAssertTrue(temporary.hasSuffix(".tmp"), temporary, file: file, line: line)
        XCTAssertTrue(error.localizedDescription.contains(destination), file: file, line: line)
        XCTAssertEqual(error.localizedDescription,
                       "open(\(temporary)) for \(destination): " + String(cString: strerror(code)), file: file, line: line)
    }
}
