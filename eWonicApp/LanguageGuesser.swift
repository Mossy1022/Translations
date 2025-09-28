// LanguageGuesser.swift
import NaturalLanguage

enum LanguageGuesser {
  static func base2(for text: String) -> String? {
    let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }

    let r = NLLanguageRecognizer()
    r.processString(s)
    if let lang = r.dominantLanguage {
      let conf = r.languageHypotheses(withMaximum: 2)[lang] ?? 0
      if conf >= 0.55 { return map(lang.rawValue) }
    }
    // gentle accents fallback
    if s.range(of: #"[áéíóúñ¿¡]"#, options: .regularExpression) != nil { return "es" }
    return nil
  }

  private static func map(_ raw: String) -> String? {
    switch raw {
    case "en": return "en"
    case "es": return "es"
    case "fr": return "fr"
    case "de": return "de"
    case "ja": return "ja"
    case "zh", "zh-Hans", "zh-Hant": return "zh"
    default: return nil
    }
  }
}
