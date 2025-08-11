//
//  TurnAssembler.swift
//  eWonicApp
//
//  Created by Evan Moscoso on 8/9/25.
//


//
//  TurnAssembler.swift
//  eWonicApp
//
//  Listener-side buffer that decides when it is safe to speak.
//

import Foundation

final class TurnAssembler {

  typealias CommitHandler = (String, BoundaryReason) -> Void

  var targetLanguage: String = "en-US"
  var onCommit: CommitHandler?

  private var carry: String = ""
  private var lastTurn: UUID?
  private var timer: DispatchSourceTimer?
  private var lastReason: BoundaryReason = .asrFinal

  func reset() {
    timer?.cancel(); timer = nil
    carry = ""
    lastTurn = nil
    lastReason = .asrFinal
  }

  func updateTargetLanguage(_ code: String) {
    targetLanguage = code
  }

  func ingest(_ m: MessageData) {
    // new speaker turn → flush any carry immediately
    if lastTurn == nil || m.turnId != lastTurn {
      if !carry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        commitNow(text: carry, reason: .asrFinal)
      }
      carry = ""
      cancelTimer()
      lastTurn = m.turnId
    }

    let appended = carry.isEmpty ? m.originalText : (carry + " " + m.originalText)
    let trimmed  = appended.trimmingCharacters(in: .whitespacesAndNewlines)

    if endsWithTerminalPunct(trimmed) {
      cancelTimer()
      commitNow(text: trimmed, reason: .punctuation)
      return
    }

    // no punctuation → debounce based on language + boundary
    carry = trimmed
    lastReason = m.boundaryReason
    scheduleDebounce(for: m.boundaryReason)
  }

  private func scheduleDebounce(for reason: BoundaryReason) {
    cancelTimer()
    let delay = computeDelay(for: reason)
    guard delay > 0 else {
      commitNow(text: carry, reason: reason)
      return
    }
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(deadline: .now() + delay)
    t.setEventHandler { [weak self] in
      guard let self else { return }
      self.commitNow(text: self.carry, reason: reason)
    }
    t.resume()
    timer = t
  }

  private func commitNow(text: String, reason: BoundaryReason) {
    guard !text.isEmpty else { return }
    onCommit?(text, reason)
    carry = ""
    cancelTimer()
  }

  private func cancelTimer() {
    timer?.cancel()
    timer = nil
  }

  private func computeDelay(for reason: BoundaryReason) -> TimeInterval {
    // base by language family
    let base: TimeInterval = {
      let lang = targetLanguage.split(separator: "-").first?.lowercased() ?? "en"
      switch lang {
      case "ja": return 0.65
      case "de": return 0.55
      case "es": return 0.45
      case "fr": return 0.40
      case "zh": return 0.35
      default:   return 0.30
      }
    }()

    // boundary modifiers
    let mod: TimeInterval = {
      switch reason {
      case .punctuation: return 0.00
      case .silence:     return 0.10
      case .stable:      return 0.20
      case .asrFinal:    return 0.30
      case .timeout:     return 0.45
      }
    }()

    return base + mod
  }

  private func endsWithTerminalPunct(_ s: String) -> Bool {
    guard let ch = s.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
    return ".!?;:…".contains(ch)
  }
}
