//
//  LocalTextTranslator.swift
//  eWonicApp
//
//  Sentence-level translation via Azure REST.
//  Supports either a Speech key or a Translator key.
//  ---------------------------------------------------------------------------

import Foundation

enum TranslateError: Error {
  case http(Int, String)          // status-code + body
  case empty                      // API returned no text
  case config(String)             // missing Info.plist entry
}

// ──────────────────────────────────────────────────────────────────────
// MARK: – Public actor
// ──────────────────────────────────────────────────────────────────────
actor LocalTextTranslator {

  static let shared = LocalTextTranslator()
  private init() {}

  /// Synchronous (blocking) sentence-level translation.
  /// Throws on *any* failure instead of echoing the source text.
  func translate(_ text: String,
                 from src: String,
                 to   dst: String) async throws -> String {

    guard !text.isEmpty, src != dst else { return text }

    // Azure expects two-letter ISO-639-1 codes
    let src2 = String(src.prefix(2)).lowercased()
    let dst2 = String(dst.prefix(2)).lowercased()

    // ───── credentials
    let key       = try config("AZ_KEY")
    let region    = try config("AZ_REGION")
    let resource  = (try? config("AZ_RESOURCE")) ?? "translator"   // ← NEW

    // ───── choose base URL
    let base: String
    switch resource.lowercased() {
    case "speech":
      base = "https://\(region).api.speech.microsoft.com/translator/text"
    default:            // "translator" or anything else
      base = "https://api.cognitive.microsofttranslator.com/translate"
    }

    let url = URL(string: "\(base)?api-version=3.0&from=\(src2)&to=\(dst2)")!

    // ───── build request
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(key,    forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
    req.setValue(region, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONEncoder().encode([["Text": text]])

    // ───── call API
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard
      let http = resp as? HTTPURLResponse,
      http.statusCode == 200
    else {
      throw TranslateError.http(
        (resp as? HTTPURLResponse)?.statusCode ?? 0,
        String(data: data, encoding: .utf8) ?? "<no body>")
    }

    // ───── decode payload
    struct Node: Decodable {
      struct T: Decodable { let text: String }
      let translations: [T]
    }
    let nodes = try JSONDecoder().decode([Node].self, from: data)
    guard
      let translated = nodes.first?.translations.first?.text,
      !translated.isEmpty
    else { throw TranslateError.empty }

    return translated
  }

  // ──────────────────────────────────────────────────────────────
  // MARK: – Helpers
  // ──────────────────────────────────────────────────────────────
  private func config(_ key: String) throws -> String {
    guard
      let v = Bundle.main.object(forInfoDictionaryKey: key) as? String,
      !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw TranslateError.config(key) }
    return v.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// ──────────────────────────────────────────────────────────────────────
// MARK: – Human-readable errors
// ──────────────────────────────────────────────────────────────────────
extension TranslateError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .http(let code, let body):
      return "Azure HTTP \(code) – \(body)"
    case .empty:
      return "Azure returned an empty translation"
    case .config(let key):
      return "Missing \(key) in Info.plist"
    }
  }
}
