//
//  UnifiedTranslateService.swift
//  eWonicApp
//
//  Single source of truth for sentence-level translation.
//  **Azure-only – no fallbacks.**
//

//import Foundation
//
//struct UnifiedTranslateService {
//
//  /// Translate *text* from **src** → **dst** via Azure Text Translator
//  static func translate(_ text: String,
//                        from src: String,
//                        to   dst: String) async throws -> String {
//    return try await AzureTextTranslator.translate(text,
//                                                   from: src,
//                                                   to:   dst)
//  }
//}
