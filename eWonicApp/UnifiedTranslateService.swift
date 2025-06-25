//
//  UnifiedTranslateService.swift
//  eWonicApp
//
//  Azure-only façade.
//  Swaps easily if you ever change providers, but right now it is a
//  one-liner that routes everything through AzureTextTranslator.
//

import Foundation

enum UnifiedTranslateService {

  /// Translate *text* from **src** → **dst** using Azure.
  static func translate(_ text: String,
                        from src: String,
                        to   dst: String) async throws -> String {
    try await AzureTextTranslator.translate(text, from: src, to: dst)
  }
}
