//
//  AzureTextTranslator.swift
//  eWonicApp
//
//  Created by Evan Moscoso on 6/23/25.
//


//
//  AzureTextTranslator.swift
//  eWonicApp
//
//  Sentence-level translator (Azure REST v3)
//
//  • Uses the same AZ_KEY / AZ_REGION you already store in Info.plist
//  • Returns the source text unchanged when src == dst
//

import Foundation

enum TranslateError: LocalizedError {
  case failed(String)

  /// A user-facing description of what went wrong.
  var errorDescription: String? {
    switch self {
    case .failed(let message):
      return message          // whatever you passed in when you threw
    }
  }
}

enum AzureTextTranslator {

//  private static let key    : String = {
//    guard let k = Bundle.main.object(forInfoDictionaryKey: "AZ_KEY") as? String
//    else { fatalError("AZ_KEY missing from Info.plist") }
//    return k.trimmingCharacters(in: .whitespacesAndNewlines)
//  }()
    
    private static let key : String = "FukUPpauIOzFoE9zuYug1yet91iORChpjAGrPAVbiQRipTtBMvJhJQQJ99BFACYeBjFXJ3w3AAAbACOGHek2"

  private static let region : String = {
    guard let r = Bundle.main.object(forInfoDictionaryKey: "AZ_REGION") as? String
    else { fatalError("AZ_REGION missing from Info.plist") }
    return r.trimmingCharacters(in: .whitespacesAndNewlines)
  }()

  /// Synchronously translate *text* from **src** → **dst**.
  static func translate(_ text: String,
                        from src: String,
                        to   dst: String) async throws -> String {

    guard !text.isEmpty, src != dst else { return text }

    // Azure endpoint – a single sentence fits comfortably in one call
    let url = URL(string:
      "https://api.cognitive.microsofttranslator.com/translate" +
      "?api-version=3.0&from=\(src)&to=\(dst.prefix(2))")!

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue(key,            forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
    req.setValue(region,         forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONEncoder().encode([["Text": text]])

    let (data, resp) = try await URLSession.shared.data(for: req)

      // 1️⃣ Must be an HTTP response
      guard let http = resp as? HTTPURLResponse else {
        throw TranslateError.failed("Non-HTTP response from Azure service")
      }

      // 2️⃣ Must be 200 OK
      guard http.statusCode == 200 else {
        throw TranslateError.failed("Azure HTTP \(http.statusCode)")
      }

    struct Payload: Decodable {
      struct Trans: Decodable { let text: String }
      let translations: [Trans]
    }
    let parsed = try JSONDecoder().decode([Payload].self, from: data)
    guard let translated = parsed.first?.translations.first?.text,
          !translated.isEmpty else {
      throw TranslateError.failed("Azure returned empty result")
    }
    return translated
  }
}
