import XCTest
@testable import DesignSystem

/// 验证 i18n 基建真的能解析英文（.lproj 已随资源打包，非空壳）。
final class LocalizationTests: XCTestCase {

    /// 直接从 DesignSystem 资源包的 en.lproj 读取，证明英文翻译已编译进包并可解析。
    func testEnglishStringsResolve() throws {
        let base = Bundle.module
        let enURL = try XCTUnwrap(base.url(forResource: "en", withExtension: "lproj"),
                                  "en.lproj 应随 DesignSystem 资源打包")
        let en = try XCTUnwrap(Bundle(url: enURL))
        XCTAssertEqual(en.localizedString(forKey: "智能扫描", value: nil, table: nil), "Smart Scan")
        XCTAssertEqual(en.localizedString(forKey: "卸载器", value: nil, table: nil), "Uninstaller")
        XCTAssertEqual(en.localizedString(forKey: "设置", value: nil, table: nil), "Settings")
    }

    /// 未知键回落到键本身（不崩溃、不返回空）。
    func testUnknownKeyFallsBackToKey() {
        XCTAssertEqual(xLoc("这个键不存在于任何目录"), "这个键不存在于任何目录")
    }
}
