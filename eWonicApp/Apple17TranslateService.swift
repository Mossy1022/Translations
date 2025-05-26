
import Foundation

@available(iOS, introduced: 17, obsoleted: 18)

final class Apple17TranslateService {
  static let shared = Apple17TranslateService()
  private init() {}

  @MainActor
  func preload(_ pairs: [(String, String)]) async {
    guard #available(iOS 17, *), isTranslationAvailable() else {
      print("⚠️ Local translation not available.")
      return
    }

    for (src, dst) in pairs {
      do {
        try await preloadTranslationModel(from: src, to: dst)
        print("✅ Assets ready for \(src)→\(dst)")
      } catch {
        print("❌ Preload failed for \(src)→\(dst): \(error)")
      }
    }
  }

  @MainActor
  func translate(_ text: String, from src: String, to dst: String) async throws -> String {
    guard #available(iOS 17, *), isTranslationAvailable() else {
      throw NSError(domain: "LocalTranslateService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Local translation not available."])
    }
    guard !text.isEmpty else { return text }
    return try await translateWithReflection(text: text, from: src, to: dst)
  }

  private func isTranslationAvailable() -> Bool {
    let exists = NSClassFromString("Translation.Translator") != nil
    print("🧠 isTranslationAvailable = \(exists)")
    return exists
  }

  private func createTranslator(from: String, to: String) -> NSObject? {
    guard
      let TranslatorClass = NSClassFromString("Translation.Translator") as? NSObject.Type,
      let LanguageClass = NSClassFromString("Translation.Language") as? NSObject.Type,
      let fromLang = LanguageClass.perform(NSSelectorFromString("languageWithCode:"), with: from)?.takeUnretainedValue(),
      let toLang = LanguageClass.perform(NSSelectorFromString("languageWithCode:"), with: to)?.takeUnretainedValue(),
      let instance = TranslatorClass.perform(NSSelectorFromString("initWithFrom:to:error:"), with: fromLang, with: toLang)?.takeUnretainedValue() as? NSObject
    else {
      return nil
    }

    return instance
  }

  private func preloadTranslationModel(from: String, to: String) async throws {
    guard let translator = createTranslator(from: from, to: to) else {
      throw NSError(domain: "LocalTranslateService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to create translator."])
    }

    let selector = NSSelectorFromString("downloadAssetsAndReturnError:")
    guard translator.responds(to: selector) else {
      throw NSError(domain: "LocalTranslateService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing selector: downloadAssetsAndReturnError"])
    }

    _ = translator.perform(selector, with: nil)
  }

  private func translateWithReflection(text: String, from: String, to: String) async throws -> String {
    guard let translator = createTranslator(from: from, to: to) else {
      throw NSError(domain: "LocalTranslateService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to create translator."])
    }

    let selector = NSSelectorFromString("translateText:error:")
    guard translator.responds(to: selector) else {
      throw NSError(domain: "LocalTranslateService", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing selector: translateText"])
    }

    guard let result = translator.perform(selector, with: text, with: nil)?.takeUnretainedValue() as? String else {
      throw NSError(domain: "LocalTranslateService", code: 6, userInfo: [NSLocalizedDescriptionKey: "Translation returned no result."])
    }

    return result
  }
}
