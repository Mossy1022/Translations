//
//  AzureTextTranslator.swift
//  eWonicApp
//
//  Lightweight wrapper over Microsoft Translator Text API (v3).
//

import Foundation

enum AzureTextTranslator {
  struct APIError: LocalizedError {
    let status: Int
    let body: String
    var errorDescription: String? { "Translator HTTP \(status): \(body)" }
  }

  /// Reduce BCP-47 to what the Translator endpoint expects.
  /// Special-case Chinese which prefers zh-Hans / zh-Hant.
  private static func normalize(_ code: String) -> String {
    let lower = code.lowercased()
    if lower.hasPrefix("zh") {
      if lower.contains("hant") || lower.contains("-tw") || lower.contains("-hk") || lower.contains("-mo") {
        return "zh-Hant"
      }
      // default simplified
      return "zh-Hans"
    }
    // most languages accept base 2-letter code
    return String(code.prefix(2))
  }

  static func translate(_ text: String, from src: String, to dst: String) async throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    // Prefer dedicated Translator creds if present; fall back to AZ_KEY/REGION
    let key =
      (Bundle.main.object(forInfoDictionaryKey: "AZ_TXT_KEY") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? (Bundle.main.object(forInfoDictionaryKey: "AZ_KEY")     as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

    let region =
      (Bundle.main.object(forInfoDictionaryKey: "AZ_TXT_REGION") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? (Bundle.main.object(forInfoDictionaryKey: "AZ_REGION")   as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let k = key, let r = region, !k.isEmpty, !r.isEmpty else {
      throw APIError(status: -1, body: "Missing AZ_TXT_KEY/AZ_TXT_REGION (or AZ_KEY/AZ_REGION) in Info.plist")
    }

    let fromCode = normalize(src)
    let toCode   = normalize(dst)

    var comps = URLComponents(string: "https://api.cognitive.microsofttranslator.com/translate")!
    comps.queryItems = [
      .init(name: "api-version", value: "3.0"),
      .init(name: "from",        value: fromCode),
      .init(name: "to",          value: toCode)
    ]

    var req = URLRequest(url: comps.url!)
    req.httpMethod = "POST"
    req.addValue(k, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
    req.addValue(r, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
    req.addValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
    req.addValue(UUID().uuidString, forHTTPHeaderField: "X-ClientTraceId") // helpful for Azure diagnostics
    req.httpBody = try JSONSerialization.data(withJSONObject: [["Text": trimmed]])

    let (data, resp) = try await URLSession.shared.data(for: req)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
    guard (200..<300).contains(status) else {
      let body = String(data: data, encoding: .utf8) ?? "?"
      throw APIError(status: status, body: body)
    }

    // Shape: [ { "translations":[ { "text":"...", "to":"xx" } ] } ]
    guard
      let arr = try JSONSerialization.jsonObject(with: data) as? [[String:Any]],
      let translations = arr.first?["translations"] as? [[String:Any]],
      let first = translations.first?["text"] as? String
    else {
      throw APIError(status: 200, body: "Malformed response")
    }

    return first
  }
}
