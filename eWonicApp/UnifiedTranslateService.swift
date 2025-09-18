//
//  UnifiedTranslateService.swift
//  eWonicApp
//
//  Single source of truth for sentence-level translation.
//  Prefers on-device translation when iOS 26 is available.
//

import Foundation

enum UnifiedTranslateService {

  /// Translate *text* from **src** → **dst**. When running on iOS 26 or
  /// newer the call prefers the local offline translator so the experience
  /// continues to work without a network connection. We fall back to Azure
  /// when the offline tables do not yet cover the language pair.
  static func translate(_ text: String,
                        from src: String,
                        to   dst: String) async throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    if #available(iOS 26.0, *) {
      let service = Apple26OfflineTranslationService.shared
      do {
        let result = try service.translateWithDiagnostics(text, from: src, to: dst)
        let srcFamily = String(src.prefix(2)).lowercased()
        let dstFamily = String(dst.prefix(2)).lowercased()
        if result.modified || srcFamily == dstFamily {
          return result.text
        }
      } catch {
        // Continue to Azure below.
      }
    }

    return try await AzureTextTranslator.translate(text, from: src, to: dst)
  }
}
