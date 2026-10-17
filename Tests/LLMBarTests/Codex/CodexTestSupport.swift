import Foundation
@testable import LLMBar

/// Unsigned test JWT; only the payload matters to LLMBar.
func codexJWT(_ claims: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: claims)
    let payload = data.base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    return "e30.\(payload).signature"
}

/// Access token whose `name` claim identifies it in assertions.
func codexAccessToken(_ name: String, expiresIn: TimeInterval = 3600) -> String {
    codexJWT(["name": name, "exp": Date().addingTimeInterval(expiresIn).timeIntervalSince1970])
}

func codexAuthJSON(accessToken: String, refreshToken: String? = "refresh", accountID: String? = "acct",
                   idToken: String? = nil, lastRefresh: String? = nil) throws -> Data {
    var tokens: [String: Any] = ["access_token": accessToken, "futureTokenField": "preserved"]
    tokens["refresh_token"] = refreshToken
    tokens["account_id"] = accountID
    tokens["id_token"] = idToken ?? codexJWT([
        "https://api.openai.com/auth": ["chatgpt_plan_type": "plus", "chatgpt_account_id": "acct"]
    ])
    var root: [String: Any] = ["tokens": tokens, "auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull()]
    root["last_refresh"] = lastRefresh
    return try JSONSerialization.data(withJSONObject: root)
}
