import Foundation

struct UnifiedTranslateService {
  static func translate(_ text: String,
                        from src: String,
                        to   dst: String) async throws -> String {
    if #available(iOS 18, *) {
      return try await Apple18TranslationService.shared.translate(text,
                                                                  from: src,
                                                                  to:   dst)
    }
    throw NSError(domain: "Translate", code: -1,
                  userInfo: [NSLocalizedDescriptionKey: "iOS 18 required"])
  }
}
