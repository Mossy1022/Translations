//
//  MessageData.swift
//  eWonicMVP
//
//  Created by Evan Moscoso on 5/18/25.
//

import Foundation

struct MessageData: Codable {
    let id: UUID
    let originalText: String
    let sourceLanguageCode: String // Speaker's language, e.g., "en-US" (BCP-47)
    let targetLanguageCode: String? // Optional; unused when broadcasting to many peers
    let isFinal: Bool            // true if final transcript
    let timestamp: TimeInterval
}
