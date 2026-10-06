import XCTest
@testable import ScrobbleCore

final class ScrobbleCoreTests: XCTestCase {
    func testVersionIsThreePartSemver() {
        let parts = ScrobbleCore.version.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
    }
}
