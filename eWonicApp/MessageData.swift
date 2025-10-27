//
//  MessageData.swift
//  eWonicMVP
//
//  Created by Evan Moscoso on 5/18/25.
//

import Foundation

struct MessageData: Codable {
  let id: UUID
  let turnId: UUID?        // optional; same for all chunks in a “turn”
  let seq: Int?            // optional; 0,1,2… within a turn
  let originalText: String // RAW text as spoken by sender
  let sourceLanguageCode: String // BCP-47 of the SPEAKER (e.g., "en-US")
  let isFinal: Bool
  let timestamp: TimeInterval
  let mode: String?        // "peer" or "convention" (optional hint)
}
