import Foundation

@available(iOS 26.0, *)
final class Apple26OfflineTranslationService {

  static let shared = Apple26OfflineTranslationService()
  private let lexicon = OfflineLexicon()

  private init() {}

  struct OfflineTranslationResult {
    let text: String
    let modified: Bool
  }

  func translate(_ text: String, from src: String, to dst: String) async throws -> String {
    return try translateWithDiagnostics(text, from: src, to: dst).text
  }

  func translateWithDiagnostics(_ text: String,
                                from src: String,
                                to dst: String) throws -> OfflineTranslationResult {
    return try lexicon.translate(text, from: src, to: dst)
  }

  func supportsPair(from src: String, to dst: String) -> Bool {
    return lexicon.supportsPair(from: src, to: dst)
  }
}

@available(iOS 26.0, *)
private enum OfflineTranslationError: LocalizedError {
  case unsupportedLanguagePair(src: String, dst: String)

  var errorDescription: String? {
    switch self {
    case .unsupportedLanguagePair(let src, let dst):
      return "Offline translator does not support \(src) → \(dst)."
    }
  }
}

@available(iOS 26.0, *)
private struct OfflineLexicon {

  struct Pair: Hashable {
    let src: String
    let dst: String
  }

  struct OfflineTable {
    private let phraseMap: [String: String]
    private let wordMap: [String: String]

    init(phrases: [String: String], words: [String: String]) {
      self.phraseMap = OfflineTable.normalize(phrases)
      self.wordMap   = OfflineTable.normalize(words)
    }

    private init(normalizedPhrases: [String: String], normalizedWords: [String: String]) {
      self.phraseMap = normalizedPhrases
      self.wordMap   = normalizedWords
    }

    func inverted() -> OfflineTable {
      var phrases: [String: String] = [:]
      for (key, value) in phraseMap {
        let normalized = OfflineTable.normalizeKey(value)
        if phrases[normalized] == nil {
          phrases[normalized] = key
        }
      }

      var words: [String: String] = [:]
      for (key, value) in wordMap {
        let normalized = OfflineTable.normalizeKey(value)
        if words[normalized] == nil {
          words[normalized] = key
        }
      }

      return OfflineTable(normalizedPhrases: phrases, normalizedWords: words)
    }

    func apply(to original: String) -> (String, Bool) {
      let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
      let normalized = OfflineTable.normalizeKey(trimmed)

      if let phrase = phraseMap[normalized], !phrase.isEmpty {
        let rebuilt = OfflineTable.rebuild(original: original, with: phrase)
        let changed = !phrase.caseInsensitiveCompare(trimmed).isOrderedSame
        return (rebuilt, changed)
      }

      return translateTokens(in: original)
    }

    private func translateTokens(in original: String) -> (String, Bool) {
      var result = ""
      var token = ""
      var changed = false

      func flushToken() {
        guard !token.isEmpty else { return }
        let (replacement, didChange) = translateWord(token)
        result.append(replacement)
        if didChange { changed = true }
        token.removeAll(keepingCapacity: true)
      }

      for scalar in original.unicodeScalars {
        if OfflineTable.isWordScalar(scalar) {
          token.unicodeScalars.append(scalar)
        } else {
          flushToken()
          result.unicodeScalars.append(scalar)
        }
      }

      flushToken()
      return (result, changed)
    }

    private func translateWord(_ word: String) -> (String, Bool) {
      let normalized = OfflineTable.normalizeKey(word)
      if let replacement = wordMap[normalized] {
        let adjusted = OfflineTable.matchCase(of: word, to: replacement)
        return (adjusted, true)
      }
      return (word, false)
    }

    private static func rebuild(original: String, with replacement: String) -> String {
      let prefix = original.prefix { $0.isWhitespace }
      let suffix = original.reversed().prefix { $0.isWhitespace }.reversed()
      return String(prefix) + replacement + String(suffix)
    }

    private static func normalize(_ input: [String: String]) -> [String: String] {
      var normalized: [String: String] = [:]
      for (key, value) in input {
        normalized[normalizeKey(key)] = value
      }
      return normalized
    }

    private static func normalizeKey(_ key: String) -> String {
      return key.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
    }

    private static func isWordScalar(_ scalar: UnicodeScalar) -> Bool {
      if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
        return true
      }
      return scalar == "'" || scalar == "’"
    }

    private static func matchCase(of original: String, to translation: String) -> String {
      let letters = original.unicodeScalars.filter { CharacterSet.letters.contains($0) }
      guard !letters.isEmpty else { return translation }

      let allUpper = letters.allSatisfy { CharacterSet.uppercaseLetters.contains($0) }
      if allUpper {
        return translation.uppercased()
      }

      if let first = letters.first, CharacterSet.uppercaseLetters.contains(first) {
        let scalars = translation.unicodeScalars
        guard let firstScalar = scalars.first else { return translation }
        if CharacterSet.letters.contains(firstScalar) {
          let remainder = String(scalars.dropFirst())
          return String(firstScalar).uppercased() + remainder
        }
      }

      return translation
    }
  }

  static let pivotLanguage = "en"

  private let tables: [Pair: OfflineTable]

  init() {
    self.tables = OfflineLexicon.makeTables()
  }

  func supportsPair(from rawSrc: String, to rawDst: String) -> Bool {
    let src = OfflineLexicon.normalize(rawSrc)
    let dst = OfflineLexicon.normalize(rawDst)

    if src == dst { return true }

    if tables[Pair(src: src, dst: dst)] != nil { return true }

    if src != Self.pivotLanguage,
       dst != Self.pivotLanguage,
       tables[Pair(src: src, dst: Self.pivotLanguage)] != nil,
       tables[Pair(src: Self.pivotLanguage, dst: dst)] != nil {
      return true
    }

    return false
  }

  func translate(_ text: String,
                 from rawSrc: String,
                 to rawDst: String) throws -> Apple26OfflineTranslationService.OfflineTranslationResult {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .init(text: "", modified: false)
    }

    let src = OfflineLexicon.normalize(rawSrc)
    let dst = OfflineLexicon.normalize(rawDst)

    if src == dst {
      return .init(text: text, modified: false)
    }

    if let table = tables[Pair(src: src, dst: dst)] {
      let (translated, changed) = table.apply(to: text)
      return .init(text: translated, modified: changed)
    }

    if src != Self.pivotLanguage,
       dst != Self.pivotLanguage,
       let toPivot = tables[Pair(src: src, dst: Self.pivotLanguage)],
       let fromPivot = tables[Pair(src: Self.pivotLanguage, dst: dst)] {
      let (intermediate, firstChanged) = toPivot.apply(to: text)
      let (final, secondChanged) = fromPivot.apply(to: intermediate)
      return .init(text: final, modified: firstChanged || secondChanged)
    }

    throw OfflineTranslationError.unsupportedLanguagePair(src: src, dst: dst)
  }

  private static func normalize(_ code: String) -> String {
    let lower = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    if lower.hasPrefix("zh") {
      if lower.contains("hant") || lower.contains("-tw") || lower.contains("-hk") || lower.contains("-mo") {
        return "zh-Hant"
      }
      return "zh-Hans"
    }

    return String(lower.prefix(2))
  }

  private static func makeTables() -> [Pair: OfflineTable] {
    var tables: [Pair: OfflineTable] = [:]

    for (dst, data) in LexiconData.englishToOthers {
      let table = OfflineTable(phrases: data.phrases, words: data.words)
      tables[Pair(src: pivotLanguage, dst: dst)] = table
      tables[Pair(src: dst, dst: pivotLanguage)] = table.inverted()
    }

    return tables
  }

  private enum LexiconData {
    static let englishToOthers: [String: (phrases: [String: String], words: [String: String])] = [
      "es": (
        phrases: [
          "how are you?": "¿Cómo estás?",
          "how are you": "¿Cómo estás?",
          "good morning": "Buenos días",
          "good night": "Buenas noches",
          "good afternoon": "Buenas tardes",
          "see you later": "Hasta luego",
          "nice to meet you": "Mucho gusto",
          "what is your name?": "¿Cómo te llamas?",
          "my name is": "Me llamo",
          "where is the bathroom?": "¿Dónde está el baño?",
          "i need help": "Necesito ayuda",
          "i don't understand": "No entiendo",
          "can you help me?": "¿Puedes ayudarme?",
          "how much does it cost?": "¿Cuánto cuesta?",
          "where are you from?": "¿De dónde eres?"
        ],
        words: [
          "hello": "hola",
          "hi": "hola",
          "goodbye": "adiós",
          "bye": "adiós",
          "please": "por favor",
          "thanks": "gracias",
          "thank you": "gracias",
          "thank": "gracias",
          "yes": "sí",
          "no": "no",
          "good": "bueno",
          "morning": "mañana",
          "afternoon": "tarde",
          "night": "noche",
          "help": "ayuda",
          "water": "agua",
          "food": "comida",
          "bathroom": "baño",
          "hospital": "hospital",
          "police": "policía",
          "friend": "amigo",
          "family": "familia",
          "today": "hoy",
          "tomorrow": "mañana",
          "yesterday": "ayer",
          "left": "izquierda",
          "right": "derecha",
          "straight": "recto",
          "stop": "alto",
          "where": "dónde",
          "when": "cuándo",
          "why": "por qué",
          "what": "qué",
          "who": "quién",
          "i": "yo",
          "you": "tú",
          "we": "nosotros",
          "they": "ellos",
          "speak": "hablar",
          "need": "necesitar",
          "want": "querer",
          "love": "amor",
          "danger": "peligro",
          "open": "abrir",
          "closed": "cerrado",
          "ticket": "boleto",
          "bus": "autobús",
          "train": "tren",
          "airport": "aeropuerto",
          "hotel": "hotel",
          "reservation": "reserva",
          "money": "dinero"
        ]
      ),
      "fr": (
        phrases: [
          "how are you?": "Comment ça va ?",
          "how are you": "Comment ça va ?",
          "good morning": "Bonjour",
          "good night": "Bonne nuit",
          "good afternoon": "Bon après-midi",
          "see you later": "À plus tard",
          "nice to meet you": "Enchanté",
          "what is your name?": "Comment vous appelez-vous ?",
          "my name is": "Je m'appelle",
          "where is the bathroom?": "Où sont les toilettes ?",
          "i need help": "J'ai besoin d'aide",
          "i don't understand": "Je ne comprends pas",
          "can you help me?": "Pouvez-vous m'aider ?",
          "how much does it cost?": "Combien ça coûte ?",
          "where are you from?": "D'où venez-vous ?"
        ],
        words: [
          "hello": "bonjour",
          "hi": "salut",
          "goodbye": "au revoir",
          "bye": "au revoir",
          "please": "s'il vous plaît",
          "thanks": "merci",
          "thank you": "merci",
          "thank": "merci",
          "yes": "oui",
          "no": "non",
          "good": "bon",
          "morning": "matin",
          "afternoon": "après-midi",
          "night": "nuit",
          "help": "aide",
          "water": "eau",
          "food": "nourriture",
          "bathroom": "toilettes",
          "hospital": "hôpital",
          "police": "police",
          "friend": "ami",
          "family": "famille",
          "today": "aujourd'hui",
          "tomorrow": "demain",
          "yesterday": "hier",
          "left": "gauche",
          "right": "droite",
          "straight": "tout droit",
          "stop": "arrêtez",
          "where": "où",
          "when": "quand",
          "why": "pourquoi",
          "what": "quoi",
          "who": "qui",
          "i": "je",
          "you": "vous",
          "we": "nous",
          "they": "ils",
          "speak": "parler",
          "need": "avoir besoin",
          "want": "vouloir",
          "love": "amour",
          "danger": "danger",
          "open": "ouvert",
          "closed": "fermé",
          "ticket": "billet",
          "bus": "bus",
          "train": "train",
          "airport": "aéroport",
          "hotel": "hôtel",
          "reservation": "réservation",
          "money": "argent"
        ]
      ),
      "de": (
        phrases: [
          "how are you?": "Wie geht es dir?",
          "how are you": "Wie geht es dir?",
          "good morning": "Guten Morgen",
          "good night": "Gute Nacht",
          "good afternoon": "Guten Tag",
          "see you later": "Bis später",
          "nice to meet you": "Freut mich",
          "what is your name?": "Wie heißt du?",
          "my name is": "Ich heiße",
          "where is the bathroom?": "Wo ist die Toilette?",
          "i need help": "Ich brauche Hilfe",
          "i don't understand": "Ich verstehe nicht",
          "can you help me?": "Kannst du mir helfen?",
          "how much does it cost?": "Wie viel kostet das?",
          "where are you from?": "Woher kommst du?"
        ],
        words: [
          "hello": "hallo",
          "hi": "hallo",
          "goodbye": "auf wiedersehen",
          "bye": "tschüss",
          "please": "bitte",
          "thanks": "danke",
          "thank you": "danke",
          "thank": "danke",
          "yes": "ja",
          "no": "nein",
          "good": "gut",
          "morning": "morgen",
          "afternoon": "nachmittag",
          "night": "nacht",
          "help": "hilfe",
          "water": "wasser",
          "food": "essen",
          "bathroom": "toilette",
          "hospital": "krankenhaus",
          "police": "polizei",
          "friend": "freund",
          "family": "familie",
          "today": "heute",
          "tomorrow": "morgen",
          "yesterday": "gestern",
          "left": "links",
          "right": "rechts",
          "straight": "geradeaus",
          "stop": "halt",
          "where": "wo",
          "when": "wann",
          "why": "warum",
          "what": "was",
          "who": "wer",
          "i": "ich",
          "you": "du",
          "we": "wir",
          "they": "sie",
          "speak": "sprechen",
          "need": "brauchen",
          "want": "wollen",
          "love": "liebe",
          "danger": "gefahr",
          "open": "offen",
          "closed": "geschlossen",
          "ticket": "ticket",
          "bus": "bus",
          "train": "zug",
          "airport": "flughafen",
          "hotel": "hotel",
          "reservation": "reservierung",
          "money": "geld"
        ]
      ),
      "ja": (
        phrases: [
          "how are you?": "お元気ですか？",
          "how are you": "お元気ですか",
          "good morning": "おはようございます",
          "good night": "おやすみなさい",
          "good afternoon": "こんにちは",
          "see you later": "また後で",
          "nice to meet you": "はじめまして",
          "what is your name?": "お名前は何ですか？",
          "my name is": "私の名前は",
          "where is the bathroom?": "トイレはどこですか？",
          "i need help": "助けが必要です",
          "i don't understand": "わかりません",
          "can you help me?": "手伝ってくれますか？",
          "how much does it cost?": "いくらですか？",
          "where are you from?": "どこから来ましたか？"
        ],
        words: [
          "hello": "こんにちは",
          "hi": "やあ",
          "goodbye": "さようなら",
          "bye": "バイバイ",
          "please": "お願いします",
          "thanks": "ありがとう",
          "thank you": "ありがとうございます",
          "thank": "ありがとう",
          "yes": "はい",
          "no": "いいえ",
          "good": "良い",
          "morning": "朝",
          "afternoon": "午後",
          "night": "夜",
          "help": "助けて",
          "water": "水",
          "food": "食べ物",
          "bathroom": "トイレ",
          "hospital": "病院",
          "police": "警察",
          "friend": "友達",
          "family": "家族",
          "today": "今日",
          "tomorrow": "明日",
          "yesterday": "昨日",
          "left": "左",
          "right": "右",
          "straight": "まっすぐ",
          "stop": "止まって",
          "where": "どこ",
          "when": "いつ",
          "why": "なぜ",
          "what": "何",
          "who": "誰",
          "i": "私",
          "you": "あなた",
          "we": "私たち",
          "they": "彼ら",
          "speak": "話す",
          "need": "必要",
          "want": "欲しい",
          "love": "愛",
          "danger": "危険",
          "open": "開く",
          "closed": "閉まっている",
          "ticket": "切符",
          "bus": "バス",
          "train": "電車",
          "airport": "空港",
          "hotel": "ホテル",
          "reservation": "予約",
          "money": "お金"
        ]
      ),
      "zh-Hans": (
        phrases: [
          "how are you?": "你好吗？",
          "how are you": "你好吗",
          "good morning": "早上好",
          "good night": "晚安",
          "good afternoon": "下午好",
          "see you later": "待会见",
          "nice to meet you": "很高兴见到你",
          "what is your name?": "你叫什么名字？",
          "my name is": "我的名字是",
          "where is the bathroom?": "洗手间在哪里？",
          "i need help": "我需要帮助",
          "i don't understand": "我不明白",
          "can you help me?": "你能帮我吗？",
          "how much does it cost?": "这个多少钱？",
          "where are you from?": "你来自哪里？"
        ],
        words: [
          "hello": "你好",
          "hi": "嗨",
          "goodbye": "再见",
          "bye": "拜拜",
          "please": "请",
          "thanks": "谢谢",
          "thank you": "谢谢你",
          "thank": "感谢",
          "yes": "是",
          "no": "不",
          "good": "好",
          "morning": "早上",
          "afternoon": "下午",
          "night": "夜晚",
          "help": "帮助",
          "water": "水",
          "food": "食物",
          "bathroom": "洗手间",
          "hospital": "医院",
          "police": "警察",
          "friend": "朋友",
          "family": "家人",
          "today": "今天",
          "tomorrow": "明天",
          "yesterday": "昨天",
          "left": "左边",
          "right": "右边",
          "straight": "直走",
          "stop": "停",
          "where": "哪里",
          "when": "什么时候",
          "why": "为什么",
          "what": "什么",
          "who": "谁",
          "i": "我",
          "you": "你",
          "we": "我们",
          "they": "他们",
          "speak": "说",
          "need": "需要",
          "want": "想要",
          "love": "爱",
          "danger": "危险",
          "open": "打开",
          "closed": "关闭",
          "ticket": "票",
          "bus": "公交",
          "train": "火车",
          "airport": "机场",
          "hotel": "酒店",
          "reservation": "预订",
          "money": "钱"
        ]
      )
    ]
  }
}
