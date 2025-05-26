import Foundation

enum TranslateError: LocalizedError {
  case network(Error)
  case invalidResponse
  case server(String)          // Message from Google
  case decoding                // JSON parse failed

  var errorDescription: String? {
    switch self {
    case .network(let e):   return "Network error: \(e.localizedDescription)"
    case .invalidResponse:  return "Unexpected response from server."
    case .server(let s):    return s          // already user-readable
    case .decoding:         return "Could not read translation data."
    }
  }
}

final class GoogleTranslateService {
  private let apiKey: String

  init() {
    guard let key = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_TRANSLATE_API_KEY") as? String,
          !key.isEmpty else {
      fatalError("⚠️ No Google Translate API key in Info.plist → GOOGLE_TRANSLATE_API_KEY")
    }
    self.apiKey = key
  }

  ///  Simple v2 text-translate
  func translateText(_ text: String,
                     from source: String,
                     to target: String,
                     completion: @escaping (Result<String,TranslateError>) -> Void)
  {
    guard !text.isEmpty else { completion(.success(text)); return }

    var comps = URLComponents(string:
      "https://translation.googleapis.com/language/translate/v2")!
    comps.queryItems = [
      URLQueryItem(name:"key",  value: apiKey),
      URLQueryItem(name:"q",    value: text),
      URLQueryItem(name:"source", value: source),
      URLQueryItem(name:"target", value: target),
      URLQueryItem(name:"format", value:"text")
    ]

    var req = URLRequest(url: comps.url!)
    req.httpMethod = "POST"

    let task = URLSession.shared.dataTask(with: req) { data, resp, err in
      if let err = err { completion(.failure(.network(err))); return }
        guard let data = data,
              let http = resp as? HTTPURLResponse else {
          print("❌ No data or bad response")
          completion(.failure(.invalidResponse))
          return
        }

        guard http.statusCode == 200 else {
          let body = String(data: data ?? Data(), encoding: .utf8) ?? "<no body>"
          print("❌ Google Translate API error – status: \(http.statusCode)")
          print("🧾 Body: \(body)")
          completion(.failure(.invalidResponse))
          return
        }

      // Google v2 returns: { "data": { "translations": [ { "translatedText": … } ] } }
      struct Wrapper: Decodable {
        struct Data: Decodable {
          struct T: Decodable { let translatedText: String }
          let translations: [T]
        }
        let data: Data
      }

      do {
          let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
          guard let raw = wrapper.data.translations.first?.translatedText else {
            completion(.failure(.decoding)); return
          }
          completion(.success(raw.htmlUnescaped()))
      } catch {
        // Might be an error payload instead of success JSON
        if let msg = String(data: data, encoding: .utf8) {
          completion(.failure(.server(msg)))
        } else {
          completion(.failure(.decoding))
        }
      }
    }
    task.resume()
  }
}
