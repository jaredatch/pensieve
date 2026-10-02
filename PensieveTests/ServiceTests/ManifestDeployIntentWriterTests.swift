import XCTest
@testable import Pensieve

extension ManifestDeployIntentTests {
    func testWriterRejectsCharsetInvalidComponents() {
        for bad in ["bad|slug", "bad slug", "bad/slug", "bad\nslug"] {
            XCTAssertThrowsError(try service.write(snapshot([record(slug: bad)]), toRoot: tempDir))
            XCTAssertThrowsError(try service.write(snapshot([record(platform: bad)]), toRoot: tempDir))
        }
    }

    func testWriterRejectsOverlengthComponents() {
        let value = String(repeating: "a", count: 65)
        XCTAssertThrowsError(try service.write(snapshot([record(slug: value)]), toRoot: tempDir))
        XCTAssertThrowsError(try service.write(snapshot([record(platform: value)]), toRoot: tempDir))
    }

    func testWriterRejectsTraversalOrHiddenSlug() {
        for slug in ["..", ".hidden", "a/b", "a\\b"] {
            XCTAssertThrowsError(try service.write(snapshot([record(slug: slug)]), toRoot: tempDir))
        }
    }

    func testWriterRejectsCaseFoldedDuplicate() {
        XCTAssertThrowsError(try service.write(snapshot([
            record(slug: "Alpha"), record(slug: "alpha", platform: "grok")
        ]), toRoot: tempDir))
    }

    func testWriterStemAlwaysEqualsSlug() throws {
        try service.write(snapshot([record(slug: "Exact.Slug")]), toRoot: tempDir)
        let path = intentPath(slug: "Exact.Slug")
        XCTAssertTrue(fileService.fileExists(at: path))
        XCTAssertEqual(try service.read(fromRoot: tempDir).deployIntents.first?.skillSlug, "Exact.Slug")
        XCTAssertTrue(try fileService.readFile(at: path).contains("slug: Exact.Slug"))
    }

    func testWriterRejectsUnparseableMachineID() {
        XCTAssertThrowsError(try service.write(snapshot([record(machine: "not-a-uuid")]), toRoot: tempDir))
    }

    func testWriterRejectsNonCanonicalMachineID() {
        XCTAssertThrowsError(try service.write(snapshot([record(machine: Self.machineA.lowercased())]), toRoot: tempDir))
    }

    func testWriterRejectsCaseVariantDuplicateMachineID() {
        XCTAssertThrowsError(try service.write(snapshot([
            record(machine: Self.machineA),
            record(machine: Self.machineA.lowercased(), slug: "beta")
        ]), toRoot: tempDir))
    }
}
