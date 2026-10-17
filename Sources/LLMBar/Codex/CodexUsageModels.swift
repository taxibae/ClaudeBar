import Foundation

/// GET /backend-api/wham/usage response. Only the default `rate_limit` is read;
/// every field may be absent and unknown fields are ignored.
struct CodexUsageResponse: Codable, Equatable {
    let planType: String?
    let rateLimit: RateLimit?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }

    struct RateLimit: Codable, Equatable {
        let primaryWindow: Window?
        let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct Window: Codable, Equatable {
        /// Percentage used, not remaining
        let usedPercent: Double?
        let limitWindowSeconds: Double?
        /// Unix seconds
        let resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAt = "reset_at"
        }

        /// Rounded up like Codex's backend client; non-positive lengths are unknown
        var durationMinutes: Int? {
            guard let seconds = limitWindowSeconds, seconds > 0 else { return nil }
            return Int((seconds / 60).rounded(.up))
        }

        var bucket: UsageBucket {
            let formatter = ISO8601DateFormatter()
            return UsageBucket(
                utilization: usedPercent,
                resetsAt: resetAt.map { formatter.string(from: Date(timeIntervalSince1970: $0)) }
            )
        }
    }
}
