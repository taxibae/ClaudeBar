import XCTest
@testable import LLMBar

final class CodexUsageAdapterTests: XCTestCase {
    private func decode(_ json: String) throws -> UsageSnapshot {
        CodexUsageAdapter.snapshot(from: try JSONDecoder().decode(CodexUsageResponse.self, from: Data(json.utf8)))
    }

    private func quotaRows(_ snapshot: UsageSnapshot, section: String) -> [UsageQuotaRow] {
        snapshot.sections.first { $0.id == section }?.rows.compactMap {
            if case .quota(let row) = $0 { return row }
            return nil
        } ?? []
    }

    func testFiveHourAndWeeklyWindowsMapToSectionsAlertsAndResetDates() throws {
        let snapshot = try decode("""
        {"plan_type":"plus","rate_limit":{"allowed":true,
          "primary_window":{"used_percent":32,"limit_window_seconds":18000,"reset_after_seconds":100,"reset_at":1893456000},
          "secondary_window":{"used_percent":58.4,"limit_window_seconds":604800,"reset_at":1893888000}},
         "credits":{"has_credits":false}}
        """)
        XCTAssertEqual(snapshot.providerID, "codex")
        XCTAssertEqual(snapshot.menuBarPercent, 32)
        XCTAssertEqual(snapshot.sections.map(\.id), ["plan", "weekly"])
        XCTAssertEqual(snapshot.sections.first?.title, .localized("section.codex_plan_usage"))
        XCTAssertEqual(snapshot.sections.first?.showsPlan, true)

        let fiveHour = try XCTUnwrap(quotaRows(snapshot, section: "plan").first)
        XCTAssertEqual(fiveHour.id, "five_hour")
        XCTAssertEqual(fiveHour.windowDurationMinutes, 300)
        XCTAssertEqual(fiveHour.bucket.percent, 32)
        XCTAssertEqual(fiveHour.bucket.resetDate, Date(timeIntervalSince1970: 1893456000))
        XCTAssertEqual(fiveHour.subtitle, .reset(.relative))

        let weekly = try XCTUnwrap(quotaRows(snapshot, section: "weekly").first)
        XCTAssertEqual(weekly.windowDurationMinutes, 10080)
        XCTAssertEqual(weekly.bucket.percent, 58)
        XCTAssertEqual(weekly.bucket.resetDate, Date(timeIntervalSince1970: 1893888000))
        XCTAssertEqual(weekly.subtitle, .reset(.absolute))

        XCTAssertEqual(snapshot.trackedLimits.map(\.id), ["five_hour", "weekly"])
        XCTAssertEqual(snapshot.trackedLimits.map(\.name), [.localized("limit.codex_five_hour"), .localized("limit.codex_weekly")])
        XCTAssertTrue(snapshot.trackedLimits.allSatisfy { $0.resetBodyKey == "notification.codex_reset_body" })
    }

    func testWindowsArePlacedByDurationNotSlot() throws {
        let snapshot = try decode("""
        {"rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":604800,"reset_at":1893888000}}}
        """)
        XCTAssertNil(snapshot.menuBarPercent)
        XCTAssertTrue(quotaRows(snapshot, section: "plan").isEmpty, "No five-hour window may be invented")
        XCTAssertEqual(quotaRows(snapshot, section: "weekly").map(\.bucket.percent), [12])
        XCTAssertEqual(snapshot.trackedLimits.map(\.id), ["weekly"])
    }

    func testMissingPercentagesUnknownAndMissingDurationsAreOmitted() throws {
        let snapshot = try decode("""
        {"rate_limit":{
          "primary_window":{"used_percent":null,"limit_window_seconds":18000,"reset_at":1893456000},
          "secondary_window":{"used_percent":40,"limit_window_seconds":86400}}}
        """)
        XCTAssertEqual(snapshot.sections.map(\.id), ["plan"])
        XCTAssertTrue(quotaRows(snapshot, section: "plan").isEmpty, "A missing percentage must not become 0%")
        XCTAssertTrue(snapshot.trackedLimits.isEmpty)

        let noDuration = try decode("""
        {"rate_limit":{"primary_window":{"used_percent":40,"reset_at":1893456000}}}
        """)
        XCTAssertTrue(noDuration.trackedLimits.isEmpty)
    }

    func testEmptyResponseKeepsOnlyThePlanHeader() throws {
        let snapshot = try decode("{}")
        XCTAssertEqual(snapshot.sections.map(\.id), ["plan"])
        XCTAssertTrue(snapshot.sections[0].rows.isEmpty)
        XCTAssertNil(snapshot.menuBarPercent)
    }

    func testPlanBadge() {
        XCTAssertEqual(CodexUsageAdapter.planBadge("plus"), "Plus")
        XCTAssertEqual(CodexUsageAdapter.planBadge("pro"), "Pro")
        XCTAssertNil(CodexUsageAdapter.planBadge(""))
        XCTAssertNil(CodexUsageAdapter.planBadge("unknown"))
        XCTAssertNil(CodexUsageAdapter.planBadge(nil))
    }
}
