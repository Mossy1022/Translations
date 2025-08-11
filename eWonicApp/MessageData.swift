//
//  MessageData.swift
//  eWonicMVP
//
//  Wire-level transcript frame sent over Multipeer.
//

import Foundation

enum BoundaryReason: String, Codable {
  case punctuation   // strong boundary . ! ? ; : …
  case silence       // long pause
  case timeout       // hit max-segment wall
  case stable        // text stopped changing for a moment
  case asrFinal      // recognizer finalized without terminal punctuation
}

struct MessageData: Codable {
  let id: UUID
  let originalText: String
  let sourceLanguageCode: String
  let isFinal: Bool
  let timestamp: TimeInterval
  let turnId: UUID
  let segmentIndex: Int
  let boundaryReason: BoundaryReason
}
