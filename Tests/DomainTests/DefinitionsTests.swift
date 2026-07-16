import XCTest
@testable import Domain

final class DefinitionsTests: XCTestCase {

    func testBundledDefinitionsLoad() {
        let lib = DefinitionsLibrary.bundled()
        XCTAssertGreaterThan(lib.version, 0)
        XCTAssertFalse(lib.definitions.isEmpty, "内置定义库不应为空")
    }

    func testRiskyDefinitionsNotDefaultSelected() {
        let lib = DefinitionsLibrary.bundled()
        for def in lib.definitions where def.safety != .safe {
            XCTAssertFalse(def.safety.defaultSelected, "非 safe 的定义不应默认勾选：\(def.id)")
        }
    }

    func testEveryDefinitionHasPaths() {
        let lib = DefinitionsLibrary.bundled()
        for def in lib.definitions {
            XCTAssertFalse(def.paths.isEmpty, "定义缺少路径：\(def.id)")
        }
    }

    func testBundledRuleDSLConstraintsDecode() throws {
        let lib = DefinitionsLibrary.bundled()
        let archive = try XCTUnwrap(lib.definitions.first { $0.id == "xcode-archives" })
        XCTAssertEqual(archive.constraints?.minimumAgeDays, 180)
        XCTAssertEqual(archive.constraints?.recovery, .trash)
        XCTAssertEqual(archive.constraints?.regenerationCost, .high)

        let firmware = try XCTUnwrap(lib.definitions.first { $0.id == "ios-firmware" })
        XCTAssertEqual(firmware.constraints?.minimumAgeDays, 30)
        XCTAssertEqual(firmware.constraints?.recovery, .redownload)
    }

    func testKillSwitchRemovesDisabledDefinitionOnlyFromActiveSet() {
        let first = CleanupDefinition(id: "a", category: "system-junk", title: "A",
                                      description: "", paths: ["~/Library/Caches/A"])
        let second = CleanupDefinition(id: "b", category: "system-junk", title: "B",
                                       description: "", paths: ["~/Library/Caches/B"])
        let library = DefinitionsLibrary(version: 1, definitions: [first, second],
                                         disabledDefinitionIDs: ["a"])
        XCTAssertEqual(library.definitions.count, 2)
        XCTAssertEqual(library.activeDefinitions.map(\.id), ["b"])
    }
}
