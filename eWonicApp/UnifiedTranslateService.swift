import Foundation

enum TranslationEngine { case apple17, apple18 }

struct UnifiedTranslateService {

  static func translate(_ text: String,
                        from src: String,
                        to   dst: String) async throws
                        -> (String, TranslationEngine) {

    // iOS 18 path — SwiftUI bridge
    if #available(iOS 18, *) {
      let out = try await Apple18TranslateService.shared
                   .translate(text, from: src, to: dst)
      return (out, .apple18)
    }

    // iOS 17 path — private reflection
    if #available(iOS 17, *) {
      let out = try await Apple17TranslateService.shared
                   .translate(text, from: src, to: dst)
      return (out, .apple17)
    }

    throw NSError(domain: "Translate", code:-1,
                  userInfo:[NSLocalizedDescriptionKey:"Unsupported OS"])
  }
}
