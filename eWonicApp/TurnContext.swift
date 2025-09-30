import Foundation

struct LangVotes {
  private(set) var englishScore: Double = 0
  private(set) var spanishScore: Double = 0
  private var lastUpdate: Date = Date()
  private let decayHalfLife: TimeInterval = 2.8

  private let englishStopwords: Set<String> = [
    "the","and","to","of","a","in","that","it","is","you","for","on","with","as","have","be","at","or","this","but"
  ]

  private let spanishStopwords: Set<String> = [
    "el","la","y","de","que","en","a","los","se","del","las","por","un","para","con","no","una","su","al","lo"
  ]

  mutating func observe(text: String, now: Date = Date()) {
    applyDecay(now: now)
    guard !text.isEmpty else { return }

    let tokens = LangVotes.tokens(in: text)
    if tokens.isEmpty { return }

    let englishHits = tokens.filter { englishStopwords.contains($0) }.count
    let spanishHits = tokens.filter { spanishStopwords.contains($0) }.count

    let accented = text.reduce(into: 0) { partial, char in
      if "áéíóúñÁÉÍÓÚÑ".contains(char) { partial += 1 }
    }

    englishScore += Double(englishHits) * 1.2 + Double(tokens.count - englishHits) * 0.05
    spanishScore += Double(spanishHits) * 1.2 + Double(tokens.count - spanishHits) * 0.05
    spanishScore += Double(accented) * 0.6

    lastUpdate = now
  }

  mutating func biasToward(base: String, weight: Double = 0.3) {
    if base.lowercased().hasPrefix("en") {
      englishScore += weight
    } else if base.lowercased().hasPrefix("es") {
      spanishScore += weight
    }
  }

  private mutating func applyDecay(now: Date) {
    let dt = now.timeIntervalSince(lastUpdate)
    guard dt > 0 else { return }
    let decay = exp(-dt / decayHalfLife)
    englishScore *= decay
    spanishScore *= decay
    lastUpdate = now
  }

  var leadingBase: String? {
    if englishScore == 0 && spanishScore == 0 { return nil }
    return englishScore >= spanishScore ? "en" : "es"
  }

  var confidence: Double {
    let total = englishScore + spanishScore
    guard total > 0 else { return 0 }
    return abs(englishScore - spanishScore) / total
  }

  static func tokens(in text: String) -> [String] {
    text.lowercased()
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
  }
}

struct TurnContext {
  var rollingText: String = ""
  var lockedSrcBase: String?
  var votes = LangVotes()
  let startedAt: Date
  var lastGrowthAt: Date
  var committed: Bool = false
  var flipUsed: Bool = false

  mutating func update(with partial: String, now: Date = Date()) {
    guard partial != rollingText else { return }
    rollingText = partial
    votes.observe(text: partial, now: now)
    lastGrowthAt = now
  }

  mutating func lock(base: String) {
    lockedSrcBase = base
  }

  func shouldDelayForTrailingConjunction() -> Bool {
    guard !rollingText.isEmpty else { return false }
    let tokens = LangVotes.tokens(in: rollingText)
    guard let last = tokens.last else { return false }
    let delayWords: Set<String> = ["and","y","que","then","so","pero"]
    return delayWords.contains(last)
  }

  func decidedBase(defaultBase: String) -> (String, Double) {
    if let locked = lockedSrcBase { return (locked, 1.0) }
    if let leading = votes.leadingBase {
      return (leading, max(votes.confidence, 0.5))
    }
    return (defaultBase, 0.4)
  }
}

struct PhraseCommit: Identifiable {
  let id = UUID()
  let srcFull: String
  let dstFull: String
  let raw: String
  let committedAt: TimeInterval
  let decidedAt: TimeInterval
  let confidence: Double
}
