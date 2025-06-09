//
//  Apple18TranslationService.swift
//  eWonicApp
//
//  Persistent on-device translation service (iOS 18-only).
//  Caches one TranslationSession per language-pair so the model
//  stays warm for the whole conversation.
//

import Foundation

@available(iOS 18.0, *)
@MainActor
final class Apple18TranslationService {

  static let shared = Apple18TranslationService()
  private init() {}

  /// Temporary stub so the project compiles on today’s SDK.
  /// Replace with Apple’s real TranslationSession code as soon
  /// as it becomes available in the public beta.
  func translate(_ text: String,
                 from src: String,
                 to   dst: String) async throws -> String {
    // TODO: use TranslationSession once exposed.
    return text          // echo back for now
  }
}
