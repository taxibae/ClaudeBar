import XCTest
@testable import LLMBar

final class UsageBucketTests: XCTestCase {
    func testResetDateParsesBothISOForms() {
        XCTAssertNotNil(UsageBucket(utilization: 1, resetsAt: "2026-09-01T21:00:00Z").resetDate)
        XCTAssertNotNil(UsageBucket(utilization: 1, resetsAt: "2026-09-01T21:00:00.123Z").resetDate)
        XCTAssertNotNil(UsageBucket(utilization: 1, resetsAt: "2026-09-05T07:00:00.000000+00:00").resetDate)
        XCTAssertNil(UsageBucket(utilization: 1, resetsAt: "yarın").resetDate)
        XCTAssertNil(UsageBucket(utilization: 1, resetsAt: nil).resetDate)
    }

    func testResetTextIsNilOncePassed() {
        let past = UsageBucket(utilization: 50, resetsAt: "2020-01-01T00:00:00Z")
        XCTAssertNil(past.resetText(style: .relative))
        XCTAssertNil(past.remainingText())
    }
}
