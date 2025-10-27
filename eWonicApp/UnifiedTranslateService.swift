// UnifiedTranslateService.swift
import Foundation

enum UnifiedTranslateService {
  static func translate(_ text: String, from src: String, to dst: String) async throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    if #available(iOS 26.0, *) {
      // iOS 26+: strictly on-device
      Log.d("MT:on-device src=\(src) dst=\(dst) len=\(trimmed.count)")
      let out = try await AppleOnDeviceTranslator.shared.translate(trimmed, from: src, to: dst)
        let clean = out.trimmingCharacters(in: .whitespacesAndNewlines)
         // Guard against “g”/single-letter glitches
         if clean.count == 1 { return trimmed }
         return clean
    } else {
      // Older OS: online path
      Log.d("MT:online     src=\(src) dst=\(dst) len=\(trimmed.count)")
      let out = try await AzureTextTranslator.translate(trimmed, from: src, to: dst)
        let clean = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count == 1 { return trimmed }
        return clean
    }
  }
}
