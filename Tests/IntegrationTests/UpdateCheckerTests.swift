import XCTest
@testable import Infrastructure

final class UpdateCheckerTests: XCTestCase {

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isVersion("1.2.0", newerThan: "1.1.9"))
        XCTAssertTrue(UpdateChecker.isVersion("1.10.0", newerThan: "1.9.0"))   // 数字比较非字典序
        XCTAssertTrue(UpdateChecker.isVersion("2.0", newerThan: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0.0", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0.0", newerThan: "1.0.1"))
        XCTAssertTrue(UpdateChecker.isVersion("1.0.1", newerThan: "1.0"))       // 缺位补 0
    }

    func testParsesSparkleAppcast() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
          <channel>
            <item>
              <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
              <enclosure url="https://xico.app/Xico-1.0.0.dmg" sparkle:version="100"/>
            </item>
            <item>
              <sparkle:shortVersionString>1.3.0</sparkle:shortVersionString>
              <enclosure url="https://xico.app/Xico-1.3.0.dmg" sparkle:version="130"/>
            </item>
          </channel>
        </rss>
        """
        let info = try XCTUnwrap(UpdateChecker.parseLatest(Data(xml.utf8)))
        XCTAssertEqual(info.version, "1.3.0", "应选版本号最高的 item")
        XCTAssertEqual(info.downloadURL.absoluteString, "https://xico.app/Xico-1.3.0.dmg")
    }

    func testMalformedAppcastReturnsNil() {
        XCTAssertNil(UpdateChecker.parseLatest(Data("not xml".utf8)))
    }
}
