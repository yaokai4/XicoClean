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
}
