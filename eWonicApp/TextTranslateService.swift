//
//  TextTranslateService.swift
//  eWonicApp
//
//  Listener-side text translation.
//

import Foundation

protocol TextTranslateService {
  func translate(_ text: String, from srcBCP47: String?, to dstBCP47: String) async throws -> String
}

@available(iOS 18.0, *)
final class Apple18TextTranslateService: TextTranslateService {
  func translate(_ text: String, from srcBCP47: String?, to dstBCP47: String) async throws -> String {
    // placeholder; swap to TranslationSession when public
    return text
  }
}

final class AzureTextTranslateService: TextTranslateService {

  private let key: String
  private let region: String

  init?() {
    guard
      let k = Bundle.main.object(forInfoDictionaryKey: "AZ_TR_KEY") as? String,
      let r = Bundle.main.object(forInfoDictionaryKey: "AZ_TR_REGION") as? String
    else { return nil }
    key = k.trimmingCharacters(in: .whitespacesAndNewlines)
    region = r.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func translate(_ text: String, from srcBCP47: String?, to dstBCP47: String) async throws -> String {
    guard !text.isEmpty else { return "" }
    let endpoint = "https://api.cognitive.microsofttranslator.com/translate?api-version=3.0"
    let src = srcBCP47.flatMap { Self.toAzureCode($0) }
    let dst = Self.toAzureCode(dstBCP47)

    var comps = URLComponents(string: endpoint)!
    var q: [URLQueryItem] = [URLQueryItem(name: "to", value: dst)]
    if let s = src { q.append(URLQueryItem(name: "from", value: s)) }
    comps.queryItems = q

    var req = URLRequest(url: comps.url!)
    req.httpMethod = "POST"
    req.addValue(key,                forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
    req.addValue(region,             forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
    req.addValue("application/json", forHTTPHeaderField: "Content-Type")
    req.addValue(UUID().uuidString,  forHTTPHeaderField: "X-ClientTraceId")
    let body = [["Text": text]]
    req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
      throw NSError(domain: "AzureTextTranslate", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
    }

    struct TXResp: Decodable { struct T: Decodable { let text: String }; let translations: [T] }
    let parsed = try JSONDecoder().decode([TXResp].self, from: data)
    return parsed.first?.translations.first?.text ?? text
  }

  private static func toAzureCode(_ bcp47: String) -> String {
    bcp47.split(separator: "-").first.map(String.init)?.lowercased() ?? bcp47.lowercased()
  }
}

enum TextTranslatorFactory {
  static func make() -> TextTranslateService {
    if #available(iOS 18.0, *), let svc = try? Apple18TextTranslateService() { return svc }
    if let az = AzureTextTranslateService() { return az }
    struct Echo: TextTranslateService { func translate(_ t: String, from _: String?, to _: String) async throws -> String { t } }
    return Echo()
  }
}
