import XCTest
@testable import LLMBar

final class ClaudeUsageAdapterTests: XCTestCase {
    private func adapt(_ json: String) throws -> UsageSnapshot {
        ClaudeUsageAdapter.snapshot(from: try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8)))
    }

    func testFullResponsePreservesSectionAndRowOrderAndMenuPercentage() throws {
        let snapshot = try adapt("""
        {
          "five_hour": {"utilization": 11.4, "resets_at": "2030-01-01T10:00:00Z"},
          "seven_day": {"utilization": 42.6},
          "seven_day_sonnet": {"utilization": 0},
          "seven_day_opus": {"utilization": 3},
          "seven_day_oauth_apps": {"utilization": 99},
          "cinder_cove": {"utilization": 30},
          "extra_usage": {"is_enabled": true, "monthly_limit": 5000, "used_credits": 1234.5, "utilization": 24.69, "currency": "USD"},
          "limits": [
            {"kind": "weekly_scoped", "percent": 17.2, "scope": {"model": {"display_name": "Fable"}}},
            {"kind": "weekly_scoped", "percent": 10, "scope": {"surface": {"display_name": "Claude Code"}}}
          ]
        }
        """)

        XCTAssertEqual(snapshot.providerID, "claude")
        XCTAssertEqual(snapshot.menuBarPercent, 11)
        XCTAssertEqual(snapshot.sections.map(\.id), ["plan", "weekly", "credits", "extra_usage"])
        XCTAssertEqual(snapshot.sections.map(\.showsPlan), [true, false, false, false])
        XCTAssertEqual(snapshot.sections[1].rows.map(\.id), ["seven_day", "seven_day_sonnet", "seven_day_opus", "model:fable"])
        XCTAssertEqual(snapshot.trackedLimits.map(\.id), ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus", "model:fable", "extra_usage"])
        XCTAssertEqual(snapshot.trackedLimits.map(\.bucket.percent), [11, 43, 0, 3, 17, 25])
        guard case .quota(let session) = snapshot.sections[0].rows[0],
              case .quota(let sonnet) = snapshot.sections[1].rows[1],
              case .quota(let model) = snapshot.sections[1].rows[3],
              case .quota(let credit) = snapshot.sections[2].rows[0],
              case .spending(let spending) = snapshot.sections[3].rows[0] else {
            return XCTFail("Expected quota and spending rows")
        }
        XCTAssertEqual(session.windowDurationMinutes, 300)
        XCTAssertEqual(session.subtitle, .reset(.relative))
        XCTAssertEqual(sonnet.subtitleText(), L("usage.sonnet_not_used"))
        XCTAssertEqual(model.title, .formatted("usage.model_only", "Fable"))
        XCTAssertEqual(credit.subtitle, .reset(.expires))
        XCTAssertEqual(spending.usedAmount, 12.345)
        XCTAssertEqual(spending.limitAmount, 50)
        XCTAssertEqual(spending.usedAmountText, Money.format(cents: 1234.5, currency: "USD", fractionDigits: 2))
        XCTAssertEqual(spending.limitAmountText, Money.format(cents: 5000, currency: "USD", fractionDigits: 0))
    }

    func testNullBucketsStayHiddenAndZeroOpusRemainsTrackedForReset() throws {
        let snapshot = try adapt("""
        {"five_hour":{"utilization":null}, "seven_day":null,
         "seven_day_sonnet":{"utilization":null}, "seven_day_opus":{"utilization":0},
         "cinder_cove":{"utilization":null}, "extra_usage":{"is_enabled":false}}
        """)
        XCTAssertEqual(snapshot.sections.map(\.id), ["plan"])
        XCTAssertTrue(snapshot.sections[0].rows.isEmpty)
        // The original menu label shows zero when five_hour exists but its utilization is null.
        XCTAssertEqual(snapshot.menuBarPercent, 0)
        XCTAssertEqual(snapshot.trackedLimits.map(\.id), ["seven_day_opus"])
        XCTAssertEqual(snapshot.trackedLimits[0].bucket.percent, 0)
        XCTAssertNil(try adapt("{}").menuBarPercent)
    }

    func testDynamicModelsKeepLegacyNullPercentageAndFilterNonWeeklyScopes() throws {
        let snapshot = try adapt("""
        {"limits":[
          {"kind":"weekly_scoped", "percent":null, "scope":{"model":{"display_name":"Future"}}},
          {"kind":"session_scoped", "percent":90, "scope":{"model":{"display_name":"Other"}}}
        ]}
        """)
        XCTAssertEqual(snapshot.sections[1].rows.map(\.id), ["model:future"])
        XCTAssertEqual(snapshot.trackedLimits.map(\.bucket.percent), [0])
    }

    func testDisabledSpendingIsVisibleWithoutThresholdTrackingAndLocalizesReasons() throws {
        for reason in ["out_of_credits", "org_spend_cap_reached", "org_level_disabled_until", "future_reason"] {
            let response = try JSONDecoder().decode(UsageResponse.self, from: JSONSerialization.data(withJSONObject: [
                "extra_usage": ["is_enabled": false, "disabled_reason": reason]
            ]))
            let snapshot = ClaudeUsageAdapter.snapshot(from: response)
            guard case .spending(let spending) = snapshot.sections.last?.rows.first else {
                return XCTFail("A disabled reason must remain visible")
            }
            let suffix = reason == "future_reason" ? "generic" : reason
            XCTAssertEqual(spending.disabledReason?.text, L("usage.extra_disabled.\(suffix)"))
            XCTAssertEqual(spending.usedAmountText, Money.format(cents: 0, currency: nil, fractionDigits: 2))
            XCTAssertEqual(spending.limitAmountText, L("usage.unlimited"))
            XCTAssertTrue(snapshot.trackedLimits.isEmpty)
        }
    }

    func testSpendingFallbackPercentageAndMonthlyResetMatchOriginal() throws {
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data("""
        {"extra_usage":{"is_enabled":true,"monthly_limit":2000,"used_credits":501}}
        """.utf8))
        let snapshot = ClaudeUsageAdapter.snapshot(from: response)
        guard case .spending(let spending) = snapshot.sections.last?.rows.first else {
            return XCTFail("Expected spending row")
        }
        let now = ISO8601.parse("2026-12-31T12:00:00Z")!
        XCTAssertEqual(spending.percent, 25)
        XCTAssertEqual(snapshot.trackedLimits[0].bucket.percent, 25)
        XCTAssertEqual(spending.resetDateText(now: now), response.extraUsage?.resetDateText(now: now))
    }
}
