import Foundation

struct UnifiedTranslateService {
  /// Translate text from src → dst using Azure Text Translator
  static func translate(_ text: String,
                        from src: String,
                        to dst: String) async throws -> String {
    let key    = (Bundle.main.object(forInfoDictionaryKey: "AZ_KEY") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let region = (Bundle.main.object(forInfoDictionaryKey: "AZ_REGION") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

    let from = src.split(separator: "-").first ?? Substring(src)
    let to   = dst.split(separator: "-").first ?? Substring(dst)

    var comps = URLComponents(string: "https://api.cognitive.microsofttranslator.com/translate")!
    comps.queryItems = [
      URLQueryItem(name: "api-version", value: "3.0"),
      URLQueryItem(name: "from", value: String(from)),
      URLQueryItem(name: "to",   value: String(to))
    ]
    var req = URLRequest(url: comps.url!)
    req.httpMethod = "POST"
    req.addValue(key,    forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
    req.addValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
    req.addValue("application/json", forHTTPHeaderField: "Content-Type")
    let body = [["Text": text]]
    req.httpBody = try JSONEncoder().encode(body)

    let (data, _) = try await URLSession.shared.data(for: req)
    struct TranslationResponse: Codable {
      struct Translation: Codable { let text: String }
      let translations: [Translation]
    }
    let decoded = try JSONDecoder().decode([TranslationResponse].self, from: data)
    return decoded.first?.translations.first?.text ?? text
  }
}
