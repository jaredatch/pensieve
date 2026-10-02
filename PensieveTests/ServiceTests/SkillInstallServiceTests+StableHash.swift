import Foundation
import XCTest
@testable import Pensieve

extension SkillInstallServiceTests {
    func testStableHashSeparatesOldDelimiterForgeryPair() throws {
        let oneFileTree = tempDir + "/delimiter-one"
        let twoFileTree = tempDir + "/delimiter-two"
        try fileService.createDirectory(at: oneFileTree)
        try fileService.createDirectory(at: twoFileTree)

        let forgedContent = Data([0x78, 0x00, 0x70, 0x00, 0x2D, 0x00, 0x79])
        try forgedContent.write(to: URL(fileURLWithPath: oneFileTree + "/a"))
        try Data([0x78]).write(to: URL(fileURLWithPath: twoFileTree + "/a"))
        try Data([0x79]).write(to: URL(fileURLWithPath: twoFileTree + "/p"))

        let oldOne = Data("a\0-\0".utf8) + forgedContent + Data([0])
        let oldTwo = Data("a\0-\0x\0p\0-\0y\0".utf8)
        XCTAssertEqual(oldOne, oldTwo, "the fixture pair must collide under the retired stream")

        let installer = makeInstallService(root: tempDir + "/delimiter-store")
        XCTAssertNotEqual(
            try installer.stableContentHash(at: oneFileTree),
            try installer.stableContentHash(at: twoFileTree)
        )
    }
}
